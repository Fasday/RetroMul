// Records how the GE interpolates texture coordinates over a through-mode
// triangle: 16 random triangles a frame in a 4 x 4 grid of 120 x 68 pixel
// cells, float UVs with random fractions over an 8888 texture whose texel
// (x, y) holds (x & 255) | (y & 255) << 8 | (x >> 8 | (y >> 8) << 1) << 16
// (nearest, wrapping), so every pixel's colour gives the texel it sampled.
// The texture is 2^(5 + (f / 2) % 5) by 2^(5 + (f / 2 + 2) % 5) texels in
// frame f (32 to 512), UVs over 0..size - 1. The colour buffer goes to
// host0:/uv/frame_<n>.bin (272 rows of 512 8888 pixels), the triangles to
// host0:/uv/tris_<n>.bin (per vertex x, y in 1/16 pixel as 32-bit integers
// and u, v as 32-bit float bits).

#include <pspkernel.h>
#include <pspge.h>
#include <pspgu.h>
#include <psppower.h>
#include <stdio.h>
#include <string.h>

PSP_MODULE_INFO("GEUV", 0, 1, 0);
PSP_MAIN_THREAD_ATTR(PSP_THREAD_ATTR_USER | PSP_THREAD_ATTR_VFPU);
PSP_HEAP_SIZE_KB(2048);

#define W 480
#define H 272
#define CELLS 16
#define FRAMES 40

typedef struct {
	float u, v;
	float x, y, z;
} Vertex;

static unsigned int __attribute__((aligned(64))) setupList[4096];
static unsigned int __attribute__((aligned(64))) list[4096];
static Vertex __attribute__((aligned(64))) verts[CELLS * 3];
static unsigned int __attribute__((aligned(64))) tex[512 * 512];
static unsigned int __attribute__((aligned(64))) colors[512 * H];
static unsigned int tris[CELLS * 3 * 4];

static unsigned int *cmd;
static unsigned int rng = 0x9E3779B9;

static unsigned int next(void) {
	rng ^= rng << 13;
	rng ^= rng >> 17;
	rng ^= rng << 5;
	return rng;
}

static int irand(int lo, int hi) {
	return lo + (int)(next() % (unsigned int)(hi - lo + 1));
}

static void emit(unsigned int c, unsigned int arg) {
	*cmd++ = (c << 24) | (arg & 0xFFFFFF);
}

enum {
	VADDR = 0x01, PRIM = 0x04, BASE = 0x10, VTYPE = 0x12, LIGHTING = 0x17, CLIPENABLE = 0x1C, CULLENABLE = 0x1D,
	TEXENABLE = 0x1E, FOGENABLE = 0x1F, DITHERENABLE = 0x20, BLENDENABLE = 0x21, ALPHATEST = 0x22, ZTESTEN = 0x23,
	STENCILTEST = 0x24, ANTIALIAS = 0x25, COLORTEST = 0x27, LOGICOP = 0x28, SHADEMODE = 0x50,
	TEXADDR0 = 0xA0, TEXBUFWIDTH0 = 0xA8, TEXSIZE0 = 0xB8, TEXMODE = 0xC2, TEXFORMAT = 0xC3, TEXFILTER = 0xC6,
	TEXWRAP = 0xC7, TEXLEVEL = 0xC8, TEXFUNC = 0xC9, TEXFLUSH = 0xCB,
	MINZ = 0xD6, MAXZ = 0xD7, MASKRGB = 0xE8, MASKALPHA = 0xE9,
};

static void writeFile(const char *name, const void *p, int bytes) {
	char path[96];
	snprintf(path, sizeof(path), "host0:/uv/%s", name);
	SceUID fd = sceIoOpen(path, PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	if (fd >= 0) {
		sceIoWrite(fd, p, bytes);
		sceIoClose(fd);
	}
}

static float randUV(int size) {
	// 0..size - 1 with a random fraction of 1/65536.
	return irand(0, (size - 1) * 65536) / 65536.0f;
}

static void frame(int f) {
	int lw = 5 + (f / 2) % 5, lh = 5 + (f / 2 + 2) % 5;
	for (int c = 0; c < CELLS; c++) {
		int cx = (c % 4) * 120 * 16, cy = (c / 4) * 68 * 16;
		for (int k = 0; k < 3; k++) {
			Vertex *v = &verts[c * 3 + k];
			int x = cx + irand(16, 1888), y = cy + irand(16, 1056);
			v->x = x / 16.0f; v->y = y / 16.0f; v->z = 0;
			v->u = randUV(1 << lw); v->v = randUV(1 << lh);
			if (f & 1) {
				// whole texels
				v->u = (float)irand(0, (1 << lw) - 1);
				v->v = (float)irand(0, (1 << lh) - 1);
			}
			unsigned int *t = &tris[(c * 3 + k) * 4];
			union { float f; unsigned int u; } a, b;
			a.f = v->u; b.f = v->v;
			t[0] = x; t[1] = y; t[2] = a.u; t[3] = b.u;
		}
	}
	sceKernelDcacheWritebackAll();

	sceGuStart(GU_DIRECT, setupList);
	sceGuClearColor(0);
	sceGuClear(GU_COLOR_BUFFER_BIT);
	sceGuFinish();
	sceGuSync(0, 0);

	cmd = list;
	emit(CLIPENABLE, 0); emit(CULLENABLE, 0); emit(FOGENABLE, 0);
	emit(DITHERENABLE, 0); emit(BLENDENABLE, 0); emit(ALPHATEST, 0); emit(ZTESTEN, 0);
	emit(STENCILTEST, 0); emit(ANTIALIAS, 0); emit(COLORTEST, 0); emit(LOGICOP, 0); emit(LIGHTING, 0);
	emit(SHADEMODE, 0); emit(MASKRGB, 0); emit(MASKALPHA, 0); emit(MINZ, 0); emit(MAXZ, 0xFFFF);
	emit(TEXENABLE, 1);
	emit(TEXFUNC, 3 | (1 << 8));
	emit(TEXFILTER, 0);
	emit(TEXWRAP, 0);
	emit(TEXMODE, 0);
	emit(TEXFORMAT, 3);
	emit(TEXLEVEL, 1);
	unsigned int ta = (unsigned int)tex;
	emit(TEXADDR0, ta & 0xFFFFFF);
	emit(TEXBUFWIDTH0, ((ta >> 8) & 0x0F0000) | 512);
	emit(TEXSIZE0, lw | (lh << 8));
	emit(TEXFLUSH, 0);
	emit(VTYPE, (1 << 23) | (3 << 7) | 3);
	unsigned int a = (unsigned int)verts;
	emit(BASE, (a >> 8) & 0x0F0000);
	emit(VADDR, a & 0xFFFFFF);
	emit(PRIM, (3 << 16) | (CELLS * 3));
	emit(0x0F, 0);
	emit(0x0C, 0);
	sceKernelDcacheWritebackAll();
	int id = sceGeListEnQueue(list, cmd, -1, NULL);
	sceGeListSync(id, 0);

	const volatile unsigned int *src = (const volatile unsigned int *)0x44000000;
	for (int i = 0; i < 512 * H; i++)
		colors[i] = src[i];
	char file[64];
	snprintf(file, sizeof(file), "frame_%d.bin", f);
	writeFile(file, colors, sizeof(colors));
	snprintf(file, sizeof(file), "tris_%d.bin", f);
	writeFile(file, tris, sizeof(tris));
	scePowerTick(PSP_POWER_TICK_ALL);
}

int main(int argc, char *argv[]) {
	sceIoMkdir("host0:/uv", 0777);
	SceUID logFd = sceIoOpen("host0:/__testoutput.txt", PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	for (int y = 0; y < 512; y++)
		for (int x = 0; x < 512; x++)
			tex[y * 512 + x] = 0xFF000000 | (x & 255) | ((y & 255) << 8) | (((x >> 8) | ((y >> 8) << 1)) << 16);
	sceKernelDcacheWritebackAll();

	sceGuInit();
	sceGuStart(GU_DIRECT, setupList);
	sceGuDrawBuffer(GU_PSM_8888, (void *)0, 512);
	sceGuDispBuffer(W, H, (void *)0, 512);
	sceGuDepthBuffer((void *)0x88000, 512);
	sceGuOffset(2048 - 240, 2048 - 136);
	sceGuViewport(2048, 2048, W, H);
	sceGuScissor(0, 0, W, H);
	sceGuEnable(GU_SCISSOR_TEST);
	sceGuFinish();
	sceGuSync(0, 0);
	sceGuDisplay(1);

	for (int f = 0; f < FRAMES; f++)
		frame(f);

	if (logFd >= 0) {
		sceIoWrite(logFd, "uv: done\n", 9);
		sceIoClose(logFd);
	}
	sceGuTerm();
	SceUID fin = sceIoOpen("host0:/__testfinish.txt", PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	if (fin >= 0) {
		sceIoWrite(fin, "1", 1);
		sceIoClose(fin);
	}
	sceKernelExitGame();
	return 0;
}
