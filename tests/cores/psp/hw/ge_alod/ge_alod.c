// Records the GE's automatic level of detail (TEXLEVEL mode 0): a 256 x 256
// CLUT4 texture of zero indices with 8 levels and a CLUT per level (TEXMODE
// bit 8), CLUT entry 16 L red 32 L, green 255 - 32 L; nearest within a
// level, linear between levels (TEXFILTER min 6), so a pixel's red is 32
// times the level plus twice its 1/16 fraction (0 where it magnifies).
// 16 random triangles a frame, one per 120 x 68 pixel cell, with random
// UVs (spans of 1/4 to 64 times their size). Sets: "thr" (through mode,
// UVs in texels) and "persp" (3D: identity world and view, a projection
// with w = z, every vertex its own w in 1/8..8, UVs over 0..1 scaled by
// the texture size). The colour buffer goes to host0:/alod/<set>_<n>.bin
// (272 rows of 512 8888 pixels), the triangles to <set>_<n>_in.bin: per
// vertex screen x, y (float), w, u, v (float bits; through mode w 1).

#include <pspkernel.h>
#include <pspge.h>
#include <pspgu.h>
#include <psppower.h>
#include <stdio.h>
#include <string.h>

PSP_MODULE_INFO("GEALOD", 0, 1, 0);
PSP_MAIN_THREAD_ATTR(PSP_THREAD_ATTR_USER | PSP_THREAD_ATTR_VFPU);
PSP_HEAP_SIZE_KB(2048);

#define W 480
#define H 272
#define CELLS 16
#define FRAMES 24

typedef struct {
	float u, v;
	float x, y, z;
} Vertex;

static unsigned int __attribute__((aligned(64))) setupList[4096];
static unsigned int __attribute__((aligned(64))) list[4096];
static Vertex __attribute__((aligned(64))) verts[CELLS * 3];
static unsigned char __attribute__((aligned(64))) tex[256 * 256 / 2];
static unsigned int __attribute__((aligned(64))) clut[256];
static unsigned int __attribute__((aligned(64))) colors[512 * H];
static float inputs[CELLS * 3 * 5];

static unsigned int *cmd;
static unsigned int rng = 0x2F6B7A11;

static unsigned int next(void) {
	rng ^= rng << 13;
	rng ^= rng >> 17;
	rng ^= rng << 5;
	return rng;
}

static float frand(float lo, float hi) {
	return lo + (hi - lo) * (next() & 0xFFFFFF) / (float)0x1000000;
}

static void emit(unsigned int c, unsigned int arg) {
	*cmd++ = (c << 24) | (arg & 0xFFFFFF);
}

static unsigned int f24(float f) {
	union { float f; unsigned int u; } v;
	v.f = f;
	return v.u >> 8;
}

enum {
	VADDR = 0x01, PRIM = 0x04, BASE = 0x10, VTYPE = 0x12, LIGHTING = 0x17, CLIPENABLE = 0x1C, CULLENABLE = 0x1D,
	TEXENABLE = 0x1E, FOGENABLE = 0x1F, DITHERENABLE = 0x20, BLENDENABLE = 0x21, ALPHATEST = 0x22, ZTESTEN = 0x23,
	STENCILTEST = 0x24, ANTIALIAS = 0x25, COLORTEST = 0x27, LOGICOP = 0x28,
	WORLDNUM = 0x3A, WORLDDATA = 0x3B, VIEWNUM = 0x3C, VIEWDATA = 0x3D, PROJNUM = 0x3E, PROJDATA = 0x3F,
	VPXS = 0x42, VPYS = 0x43, VPZS = 0x44, VPXC = 0x45, VPYC = 0x46, VPZC = 0x47, OFFSETX = 0x4C, OFFSETY = 0x4D,
	SHADEMODE = 0x50, TEXSCALEU = 0x48, TEXSCALEV = 0x49, TEXOFFSETU = 0x4A, TEXOFFSETV = 0x4B,
	TEXADDR0 = 0xA0, TEXBUFWIDTH0 = 0xA8, CLUTADDR = 0xB0, CLUTADDRUPPER = 0xB1, TEXSIZE0 = 0xB8,
	TEXMAPMODE = 0xC0, TEXMODE = 0xC2, TEXFORMAT = 0xC3, CLUTLOAD = 0xC4, CLUTFORMAT = 0xC5, TEXFILTER = 0xC6,
	TEXWRAP = 0xC7, TEXLEVEL = 0xC8, TEXFUNC = 0xC9, TEXFLUSH = 0xCB,
	MINZ = 0xD6, MAXZ = 0xD7, MASKRGB = 0xE8, MASKALPHA = 0xE9,
};

static void writeFile(const char *name, const void *p, int bytes) {
	char path[96];
	snprintf(path, sizeof(path), "host0:/alod/%s", name);
	SceUID fd = sceIoOpen(path, PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	if (fd >= 0) {
		sceIoWrite(fd, p, bytes);
		sceIoClose(fd);
	}
}

static void frame(int persp, int f) {
	for (int c = 0; c < CELLS; c++) {
		int cx = (c % 4) * 120, cy = (c / 4) * 68;
		// texels per pixel: 2^-2 .. 2^6
		float scale = frand(-2.0f, 6.0f);
		float k = 1.0f;
		while (scale > 0) { k *= 2.0f; scale -= 1.0f; }
		while (scale < 0) { k *= 0.5f; scale += 1.0f; }
		k *= 1.0f + scale;
		float bu = frand(0, 64), bv = frand(0, 64);
		for (int i = 0; i < 3; i++) {
			Vertex *v = &verts[c * 3 + i];
			float sx = cx + frand(2, 118), sy = cy + frand(2, 66);
			float w = persp ? frand(0.125f, 8.0f) : 1.0f;
			float u = bu + (sx - cx) * k * frand(0.5f, 1.5f);
			float vv = bv + (sy - cy) * k * frand(0.5f, 1.5f);
			float *in = &inputs[(c * 3 + i) * 5];
			in[0] = sx; in[1] = sy; in[2] = w; in[3] = u; in[4] = vv;
			if (persp) {
				v->x = (sx - 240.0f) / 240.0f * w;
				v->y = (136.0f - sy) / 136.0f * w;
				v->z = w;
				v->u = u / 256.0f;
				v->v = vv / 256.0f;
			} else {
				v->x = sx; v->y = sy; v->z = 0;
				v->u = u; v->v = vv;
			}
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
	emit(TEXFILTER, 6);
	emit(TEXWRAP, 0);
	emit(TEXMODE, 0x100 | (7 << 16));
	emit(TEXFORMAT, 4);
	emit(TEXLEVEL, 0);
	emit(TEXMAPMODE, 0);
	emit(TEXSCALEU, f24(1.0f)); emit(TEXSCALEV, f24(1.0f)); emit(TEXOFFSETU, 0); emit(TEXOFFSETV, 0);
	unsigned int ca = (unsigned int)clut;
	emit(CLUTADDR, ca & 0xFFFFFF);
	emit(CLUTADDRUPPER, (ca >> 8) & 0x0F0000);
	emit(CLUTFORMAT, 0x00FF03);
	emit(CLUTLOAD, 32);
	unsigned int ta = (unsigned int)tex;
	for (int l = 0; l < 8; l++) {
		emit(TEXADDR0 + l, ta & 0xFFFFFF);
		emit(TEXBUFWIDTH0 + l, ((ta >> 8) & 0x0F0000) | 256);
		emit(TEXSIZE0 + l, (8 - l) | ((8 - l) << 8));
	}
	emit(TEXFLUSH, 0);
	if (persp) {
		emit(WORLDNUM, 0);
		for (int k = 0; k < 12; k++) emit(WORLDDATA, (k % 4 == 0 && k < 9) ? f24(1.0f) : 0);
		emit(VIEWNUM, 0);
		for (int k = 0; k < 12; k++) emit(VIEWDATA, (k % 4 == 0 && k < 9) ? f24(1.0f) : 0);
		// clip x = x, y = y, z = 0, w = z (column-major)
		emit(PROJNUM, 0);
		for (int k = 0; k < 16; k++) emit(PROJDATA, (k == 0 || k == 5 || k == 11) ? f24(1.0f) : 0);
		emit(VPXS, f24(240.0f)); emit(VPYS, f24(-136.0f)); emit(VPZS, f24(1000.0f));
		emit(VPXC, f24(2048.0f)); emit(VPYC, f24(2048.0f)); emit(VPZC, f24(30000.0f));
		emit(OFFSETX, (2048 - 240) << 4); emit(OFFSETY, (2048 - 136) << 4);
		emit(VTYPE, (3 << 7) | 3);
	} else {
		emit(VTYPE, (1 << 23) | (3 << 7) | 3);
	}
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
	snprintf(file, sizeof(file), "%s_%d.bin", persp ? "persp" : "thr", f);
	writeFile(file, colors, sizeof(colors));
	snprintf(file, sizeof(file), "%s_%d_in.bin", persp ? "persp" : "thr", f);
	writeFile(file, inputs, sizeof(inputs));
	scePowerTick(PSP_POWER_TICK_ALL);
}

int main(int argc, char *argv[]) {
	sceIoMkdir("host0:/alod", 0777);
	SceUID logFd = sceIoOpen("host0:/__testoutput.txt", PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	memset(tex, 0, sizeof(tex));
	for (int i = 0; i < 256; i++)
		clut[i] = 0;
	// 8888 entries: red 32 L, green 255 - 32 L.
	for (int l = 0; l < 8; l++)
		clut[16 * l] = 0xFF000000 | (32 * l) | ((255 - 32 * l) << 8);
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
		frame(0, f);
	for (int f = 0; f < FRAMES; f++)
		frame(1, f);

	if (logFd >= 0) {
		sceIoWrite(logFd, "alod: done\n", 11);
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
