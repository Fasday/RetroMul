// Records the GE's texture level of detail in slope mode (TEXLEVEL mode 2):
// 4 x 4 pixel quads, each with one w at all four vertices and its own
// TEXLODSLOPE, sampling an 8-level texture whose level k is the solid colour
// R = 32 k, G = 255 - 32 k with the mipmap-linear filter, so a pixel's red is
// 32 level + 2 fraction: twice the level of detail in 1/16 levels.
// host0:/lod/<set>_<n>.bin: the colour buffer (272 rows of 512 8888 pixels);
// host0:/lod/<set>_<n>_in.bin: per quad (68 rows of 120) its w and slope bits.
//
// Sets: "w" (slope 1, w every 24-bit float of [1, 4) in turn: 4 frames a
// binade), "ws" (w and slope random over a range that keeps the level of
// detail inside 0..7 levels).

#include <pspkernel.h>
#include <pspge.h>
#include <pspgu.h>
#include <psppower.h>
#include <stdio.h>
#include <string.h>

PSP_MODULE_INFO("GELOD", 0, 1, 0);
PSP_MAIN_THREAD_ATTR(PSP_THREAD_ATTR_USER | PSP_THREAD_ATTR_VFPU);
PSP_HEAP_SIZE_KB(1024);

#define W 480
#define H 272
#define QW (W / 4)
#define QH (H / 4)
#define NQ (QW * QH)
#define LEVELS 8

typedef struct { float u, v; unsigned int color; float x, y, z; } Vert;

static unsigned int __attribute__((aligned(64))) setupList[4096];
static unsigned int __attribute__((aligned(64))) list[NQ * 16 + 4096];
static Vert __attribute__((aligned(64))) verts[NQ * 4];
static unsigned int __attribute__((aligned(64))) colors[512 * H];
static unsigned int inputs[NQ * 2];
static unsigned int __attribute__((aligned(64))) tex[128 * 128 * 2];

static unsigned int *cmd;
static unsigned int rng = 0x7F4A7C15;

static unsigned int next(void) {
	rng ^= rng << 13;
	rng ^= rng >> 17;
	rng ^= rng << 5;
	return rng;
}

static void emit(unsigned int c, unsigned int arg) {
	*cmd++ = (c << 24) | (arg & 0xFFFFFF);
}

static unsigned int bits(float f) {
	union { float f; unsigned int u; } v;
	v.f = f;
	return v.u;
}

static float fromBits(unsigned int u) {
	union { float f; unsigned int u; } v;
	v.u = u;
	return v.f;
}

static unsigned int f24(float f) {
	return bits(f) >> 8;
}

enum {
	VADDR = 0x01, PRIM = 0x04, BASE = 0x10, VTYPE = 0x12, LIGHTING = 0x17, CLIPENABLE = 0x1C, CULLENABLE = 0x1D,
	TEXENABLE = 0x1E, FOGENABLE = 0x1F, DITHERENABLE = 0x20, BLENDENABLE = 0x21, ALPHATEST = 0x22, ZTESTEN = 0x23,
	STENCILTEST = 0x24, COLORTEST = 0x27, LOGICOP = 0x28,
	WORLDNUM = 0x3A, WORLDDATA = 0x3B, VIEWNUM = 0x3C, VIEWDATA = 0x3D, PROJNUM = 0x3E, PROJDATA = 0x3F,
	VPXS = 0x42, VPYS = 0x43, VPZS = 0x44, VPXC = 0x45, VPYC = 0x46, VPZC = 0x47,
	TEXSCALEU = 0x48, TEXSCALEV = 0x49, TEXOFFSETU = 0x4A, TEXOFFSETV = 0x4B, OFFSETX = 0x4C, OFFSETY = 0x4D,
	SHADEMODE = 0x50, MATAMBIENT = 0x55, MATALPHA = 0x58, MINZ = 0xD6, MAXZ = 0xD7, TEXADDR0 = 0xA0, TEXBUFWIDTH0 = 0xA8, TEXSIZE0 = 0xB8,
	TEXMAPMODE = 0xC0, TEXMODE = 0xC2, TEXFORMAT = 0xC3, TEXFILTER = 0xC6, TEXWRAP = 0xC7, TEXLEVEL = 0xC8,
	TEXFUNC = 0xC9, TEXFLUSH = 0xCB, TEXLODSLOPE = 0xD0, MASKRGB = 0xE8, MASKALPHA = 0xE9,
};

static void matrix(int num, int data, int n, const float *m) {
	emit(num, 0);
	for (int i = 0; i < n; i++)
		emit(data, f24(m[i]));
}

static const float ident12[12] = { 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0 };
// Clip x = x, y = y, z = 0, w = z.
static const float proj[16] = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0 };

static void makeTexture(void) {
	unsigned int *p = tex;
	for (int k = 0; k < LEVELS; k++) {
		int s = 128 >> k;
		unsigned int c = 0xFF800000 | ((unsigned int)(255 - 32 * k) << 8) | (unsigned int)(32 * k);
		for (int i = 0; i < s * s; i++)
			p[i] = c;
		p += s * s;
	}
	sceKernelDcacheWritebackAll();
}

static void baseState(void) {
	emit(CLIPENABLE, 0); emit(CULLENABLE, 0); emit(FOGENABLE, 0); emit(DITHERENABLE, 0);
	emit(BLENDENABLE, 0); emit(ALPHATEST, 0); emit(ZTESTEN, 0); emit(STENCILTEST, 0);
	emit(COLORTEST, 0); emit(LOGICOP, 0); emit(LIGHTING, 0); emit(SHADEMODE, 0);
	emit(MASKRGB, 0); emit(MASKALPHA, 0);
	emit(MATAMBIENT, 0xFFFFFF); emit(MATALPHA, 0xFF);
	emit(MINZ, 0); emit(MAXZ, 0xFFFF);
	matrix(WORLDNUM, WORLDDATA, 12, ident12);
	matrix(VIEWNUM, VIEWDATA, 12, ident12);
	matrix(PROJNUM, PROJDATA, 16, proj);
	emit(VPXS, f24(240.0f)); emit(VPYS, f24(-136.0f));
	emit(VPXC, f24(2048.0f)); emit(VPYC, f24(2048.0f));
	emit(VPZS, f24(1000.0f)); emit(VPZC, f24(32768.0f));
	emit(OFFSETX, (2048 - 240) << 4); emit(OFFSETY, (2048 - 136) << 4);
	emit(TEXENABLE, 1);
	unsigned int a = (unsigned int)tex;
	for (int k = 0; k < LEVELS; k++) {
		int s = 128 >> k;
		emit(TEXADDR0 + k, a & 0xFFFFFF);
		emit(TEXBUFWIDTH0 + k, ((a >> 24) << 16) | s);
		emit(TEXSIZE0 + k, ((7 - k) << 8) | (7 - k));
		a += s * s * 4;
	}
	emit(TEXMAPMODE, 0);
	emit(TEXMODE, (LEVELS - 1) << 16);
	emit(TEXFORMAT, 3);
	emit(TEXFILTER, 6 | (0 << 8));
	emit(TEXWRAP, 0);
	emit(TEXLEVEL, 2);
	emit(TEXFUNC, 0x103);
	emit(TEXSCALEU, f24(1.0f)); emit(TEXSCALEV, f24(1.0f));
	emit(TEXOFFSETU, 0); emit(TEXOFFSETV, 0);
	emit(TEXFLUSH, 0);
	emit(VTYPE, 3 | (7 << 2) | (3 << 7));
}

// Quad q at pixels (4 qx .. 4 qx + 4, 4 qy .. 4 qy + 4) with w at every vertex.
static void quad(int q, float w, unsigned int slopeBits) {
	int qx = q % QW, qy = q / QW;
	Vert *v = &verts[q * 4];
	for (int k = 0; k < 4; k++) {
		float px = qx * 4 + (k & 1) * 4, py = qy * 4 + (k >> 1) * 4;
		v[k].u = 0.25f + 0.5f * (k & 1);
		v[k].v = 0.25f + 0.5f * (k >> 1);
		v[k].color = 0xFFFFFFFF;
		v[k].x = (px - 240.0f) / 240.0f * w;
		v[k].y = (136.0f - py) / 136.0f * w;
		v[k].z = w;
	}
	emit(TEXLODSLOPE, slopeBits >> 8);
	unsigned int a = (unsigned int)v;
	emit(BASE, (a >> 8) & 0x0F0000);
	emit(VADDR, a & 0xFFFFFF);
	emit(PRIM, (4 << 16) | 4);
	inputs[q * 2] = bits(w);
	inputs[q * 2 + 1] = slopeBits & 0xFFFFFF00;
}

static void writeFile(const char *name, const void *p, int bytes) {
	char path[96];
	snprintf(path, sizeof(path), "host0:/lod/%s", name);
	SceUID fd = sceIoOpen(path, PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	if (fd >= 0) {
		sceIoWrite(fd, p, bytes);
		sceIoClose(fd);
	}
}

static void frame(const char *set, int n, int f) {
	memset(inputs, 0, sizeof(inputs));
	cmd = list;
	baseState();
	for (int q = 0; q < NQ; q++) {
		float w;
		unsigned int sb;
		if (set[1] == 0) {
			// "w": every 24-bit float of [1, 4): 32768 a binade, NQ a frame.
			int i = f * NQ + q;
			if (i >= 3 * 32768)
				i = 3 * 32768 - 1;
			w = fromBits(((127 + i / 32768) << 23) | ((i % 32768) << 8));
			sb = bits(1.0f);
		} else {
			// "ws": log2(w) in [-3, 6), log2(slope) chosen so log2(slope w) is in
			// [-0.9, 6.9): the level of detail inside the texture's 8 levels.
			float lw = -3.0f + 9.0f * ((next() >> 8) / 16777216.0f);
			float lsw = -0.9f + 7.8f * ((next() >> 8) / 16777216.0f);
			float e1 = lw, e2 = lsw - lw;
			// 2^x for these ranges from the float bits.
			int i1 = (int)(e1 * 8388608.0f + 127 * 8388608.0f);
			int i2 = (int)(e2 * 8388608.0f + 127 * 8388608.0f);
			// Approximate 2^x by the bits (exponent and linear mantissa): any
			// value is fine, only its bits are recorded.
			w = fromBits((unsigned int)i1 & 0xFFFFFF00);
			sb = (unsigned int)i2 & 0xFFFFFF00;
		}
		quad(q, w, sb);
	}
	emit(0x0F, 0);
	emit(0x0C, 0);
	sceKernelDcacheWritebackAll();

	sceGuStart(GU_DIRECT, setupList);
	sceGuClearColor(0);
	sceGuClear(GU_COLOR_BUFFER_BIT);
	sceGuFinish();
	sceGuSync(0, 0);
	int id = sceGeListEnQueue(list, cmd, -1, NULL);
	sceGeListSync(id, 0);

	const volatile unsigned int *src = (const volatile unsigned int *)0x44000000;
	for (int i = 0; i < 512 * H; i++)
		colors[i] = src[i];
	char file[64];
	snprintf(file, sizeof(file), "%s_%02d.bin", set, n);
	writeFile(file, colors, sizeof(colors));
	snprintf(file, sizeof(file), "%s_%02d_in.bin", set, n);
	writeFile(file, inputs, sizeof(inputs));
	scePowerTick(PSP_POWER_TICK_ALL);
}

int main(int argc, char *argv[]) {
	sceIoMkdir("host0:/lod", 0777);
	SceUID logFd = sceIoOpen("host0:/__testoutput.txt", PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	makeTexture();

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

	int frames = (3 * 32768 + NQ - 1) / NQ;
	for (int f = 0; f < frames; f++)
		frame("w", f, f);
	for (int f = 0; f < 24; f++)
		frame("ws", f, f);

	char line[64];
	snprintf(line, sizeof(line), "lod: %d w frames, 24 ws frames\n", frames);
	if (logFd >= 0) {
		sceIoWrite(logFd, line, strlen(line));
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
