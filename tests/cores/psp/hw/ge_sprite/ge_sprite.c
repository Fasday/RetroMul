// Records where a sprite samples its texture: through-mode sprites over a
// 16 x 16 texture whose texel (i, j) is red 16 i, green 16 j, clamped and
// bilinear, so a pixel's red and green are its sample position in 1/16
// texels (less half a texel) wherever that lies inside the texture.
// host0:/sprite/<set>.bin: the colour buffer (272 rows of 512 8888 pixels);
// host0:/sprite/<set>_in.bin: per sprite its cell and u0, v0, u1, v1, x0,
// y0, x1, y1 as floats.
//
// Sets: "int" (integer texel and pixel coordinates, every texel span 1..15
// over pixel spans 1..24: 1:1, exact and inexact ratios), "frac" (random
// fractional texel and pixel coordinates), "neg" (u and v decreasing).

#include <pspkernel.h>
#include <pspge.h>
#include <pspgu.h>
#include <psppower.h>
#include <stdio.h>
#include <string.h>

PSP_MODULE_INFO("GESPRITE", 0, 1, 0);
PSP_MAIN_THREAD_ATTR(PSP_THREAD_ATTR_USER | PSP_THREAD_ATTR_VFPU);
PSP_HEAP_SIZE_KB(1024);

#define W 480
#define H 272
#define CW 30
#define CH 17
#define CELLS ((W / CW) * (H / CH))

typedef struct { float u, v; float x, y, z; } Vert;

static unsigned int __attribute__((aligned(64))) setupList[4096];
static unsigned int __attribute__((aligned(64))) list[CELLS * 8 + 4096];
static Vert __attribute__((aligned(64))) verts[CELLS * 2];
static unsigned int __attribute__((aligned(64))) colors[512 * H];
static float inputs[CELLS * 8];
static unsigned int __attribute__((aligned(64))) tex[16 * 16];

static unsigned int *cmd;
static unsigned int rng = 0x3C6EF372;

static unsigned int next(void) {
	rng ^= rng << 13;
	rng ^= rng >> 17;
	rng ^= rng << 5;
	return rng;
}

static float frand(float lo, float hi) {
	return lo + (hi - lo) * ((next() >> 8) / 16777216.0f);
}

static void emit(unsigned int c, unsigned int arg) {
	*cmd++ = (c << 24) | (arg & 0xFFFFFF);
}

enum {
	VADDR = 0x01, PRIM = 0x04, BASE = 0x10, VTYPE = 0x12, LIGHTING = 0x17, CLIPENABLE = 0x1C, CULLENABLE = 0x1D,
	TEXENABLE = 0x1E, FOGENABLE = 0x1F, DITHERENABLE = 0x20, BLENDENABLE = 0x21, ALPHATEST = 0x22, ZTESTEN = 0x23,
	STENCILTEST = 0x24, COLORTEST = 0x27, LOGICOP = 0x28, SHADEMODE = 0x50,
	TEXADDR0 = 0xA0, TEXBUFWIDTH0 = 0xA8, TEXSIZE0 = 0xB8,
	TEXMAPMODE = 0xC0, TEXMODE = 0xC2, TEXFORMAT = 0xC3, TEXFILTER = 0xC6, TEXWRAP = 0xC7, TEXLEVEL = 0xC8,
	TEXFUNC = 0xC9, TEXFLUSH = 0xCB, MINZ = 0xD6, MAXZ = 0xD7, MASKRGB = 0xE8, MASKALPHA = 0xE9,
};

static void baseState(void) {
	emit(CLIPENABLE, 0); emit(CULLENABLE, 0); emit(FOGENABLE, 0); emit(DITHERENABLE, 0);
	emit(BLENDENABLE, 0); emit(ALPHATEST, 0); emit(ZTESTEN, 0); emit(STENCILTEST, 0);
	emit(COLORTEST, 0); emit(LOGICOP, 0); emit(LIGHTING, 0); emit(SHADEMODE, 0);
	emit(MASKRGB, 0); emit(MASKALPHA, 0); emit(MINZ, 0); emit(MAXZ, 0xFFFF);
	emit(TEXENABLE, 1);
	unsigned int a = (unsigned int)tex;
	emit(TEXADDR0, a & 0xFFFFFF);
	emit(TEXBUFWIDTH0, ((a >> 24) << 16) | 16);
	emit(TEXSIZE0, (4 << 8) | 4);
	emit(TEXMAPMODE, 0);
	emit(TEXMODE, 0);
	emit(TEXFORMAT, 3);
	emit(TEXFILTER, 1 | (1 << 8));
	emit(TEXWRAP, 1 | (1 << 8));
	emit(TEXLEVEL, 0);
	emit(TEXFUNC, 0x103);
	emit(TEXFLUSH, 0);
	emit(VTYPE, (1 << 23) | 3 | (3 << 7));
}

static void sprite(int c, float u0, float v0, float u1, float v1, float x0, float y0, float x1, float y1) {
	Vert *v = &verts[c * 2];
	v[0].u = u0; v[0].v = v0; v[0].x = x0; v[0].y = y0; v[0].z = 0;
	v[1].u = u1; v[1].v = v1; v[1].x = x1; v[1].y = y1; v[1].z = 0;
	unsigned int a = (unsigned int)v;
	emit(BASE, (a >> 8) & 0x0F0000);
	emit(VADDR, a & 0xFFFFFF);
	emit(PRIM, (6 << 16) | 2);
	float *in = &inputs[c * 8];
	in[0] = u0; in[1] = v0; in[2] = u1; in[3] = v1; in[4] = x0; in[5] = y0; in[6] = x1; in[7] = y1;
}

static void writeFile(const char *name, const void *p, int bytes) {
	char path[96];
	snprintf(path, sizeof(path), "host0:/sprite/%s", name);
	SceUID fd = sceIoOpen(path, PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	if (fd >= 0) {
		sceIoWrite(fd, p, bytes);
		sceIoClose(fd);
	}
}

static void run(const char *set) {
	memset(inputs, 0, sizeof(inputs));
	cmd = list;
	baseState();
	for (int c = 0; c < CELLS; c++) {
		float cx = (c % (W / CW)) * CW, cy = (c / (W / CW)) * CH;
		if (!strcmp(set, "int")) {
			// texel span 1..15 (u from 0.5 or 0), pixel span 1..24 (x), the
			// same in y with other spans.
			int du = 1 + c % 15, dx = 1 + (c / 15) % 24;
			int dv = 1 + (c / 7) % 15, dy = 1 + (c / 3) % 15;
			sprite(c, 0, 0, du, dv, cx, cy, cx + dx, cy + dy);
		} else if (!strcmp(set, "frac")) {
			float u0 = frand(0, 6), v0 = frand(0, 6), du = frand(0.2f, 9), dv = frand(0.2f, 9);
			float x0 = cx + frand(0, 3), y0 = cy + frand(0, 1.5f), dx = frand(1, 24), dy = frand(1, 14);
			sprite(c, u0, v0, u0 + du, v0 + dv, x0, y0, x0 + dx, y0 + dy);
		} else {
			float u0 = frand(6, 15), v0 = frand(6, 15), du = frand(0.2f, 6), dv = frand(0.2f, 6);
			float x0 = cx + frand(0, 3), y0 = cy + frand(0, 1.5f), dx = frand(1, 24), dy = frand(1, 14);
			sprite(c, u0, v0, u0 - du, v0 - dv, x0, y0, x0 + dx, y0 + dy);
		}
	}
	emit(0x0F, 0);
	emit(0x0C, 0);
	sceKernelDcacheWritebackAll();

	sceGuStart(GU_DIRECT, setupList);
	sceGuClearColor(0xFF0000FF);
	sceGuClear(GU_COLOR_BUFFER_BIT);
	sceGuFinish();
	sceGuSync(0, 0);
	int id = sceGeListEnQueue(list, cmd, -1, NULL);
	sceGeListSync(id, 0);

	const volatile unsigned int *src = (const volatile unsigned int *)0x44000000;
	for (int i = 0; i < 512 * H; i++)
		colors[i] = src[i];
	char file[64];
	snprintf(file, sizeof(file), "%s.bin", set);
	writeFile(file, colors, sizeof(colors));
	snprintf(file, sizeof(file), "%s_in.bin", set);
	writeFile(file, inputs, sizeof(inputs));
	scePowerTick(PSP_POWER_TICK_ALL);
}

int main(int argc, char *argv[]) {
	sceIoMkdir("host0:/sprite", 0777);
	SceUID logFd = sceIoOpen("host0:/__testoutput.txt", PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	for (int j = 0; j < 16; j++)
		for (int i = 0; i < 16; i++)
			tex[j * 16 + i] = 0xFF000000 | ((unsigned int)(16 * j) << 8) | (unsigned int)(16 * i);
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

	run("int");
	run("frac");
	run("neg");

	if (logFd >= 0) {
		sceIoWrite(logFd, "sprite: 3 sets\n", 15);
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
