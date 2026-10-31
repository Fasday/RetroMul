// Records which pixels the GE draws for a line: through-mode lines, one per
// 30 x 17 pixel cell (256 a frame), flat white on black; the colour buffer
// is read back (host0:/line/<set>_<n>.bin, 272 rows of 512 8888 pixels) with
// the lines' end points (host0:/line/<set>_<n>_in.bin: per cell x0, y0, x1,
// y1 in 1/16 pixels as 32-bit integers).
//
// Sets: "rand" (random end points anywhere in the cell, in 1/16 pixel),
// "half" (end points on the half-pixel grid: pixel corners, edge middles and
// centres, where the rules for ties show), "short" (lines under two pixels
// long), "diag" (slopes near and at 1), "aa" (random lines antialiased and
// blended source alpha over one minus it, each with its own vertex alpha:
// host0:/line/aa_<n>_col.bin, the vertex colour of each cell).

#include <pspkernel.h>
#include <pspge.h>
#include <pspgu.h>
#include <psppower.h>
#include <stdio.h>
#include <string.h>

PSP_MODULE_INFO("GELINE", 0, 1, 0);
PSP_MAIN_THREAD_ATTR(PSP_THREAD_ATTR_USER | PSP_THREAD_ATTR_VFPU);
PSP_HEAP_SIZE_KB(1024);

#define W 480
#define H 272
#define CW 30
#define CH 17
#define CELLS 256
#define FRAMES 8

typedef struct { unsigned int color; float x, y, z; } Vert;

static unsigned int __attribute__((aligned(64))) setupList[4096];
static unsigned int __attribute__((aligned(64))) list[CELLS * 4 + 4096];
static Vert __attribute__((aligned(64))) verts[CELLS * 2];
static unsigned int __attribute__((aligned(64))) colors[512 * H];
static int inputs[CELLS * 4];
static unsigned int cellColor[CELLS];

static unsigned int *cmd;
static unsigned int rng = 0x1B873593;

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
	BLENDMODE = 0xDF, BLENDFIXA = 0xE0, BLENDFIXB = 0xE1,
	MINZ = 0xD6, MAXZ = 0xD7, MASKRGB = 0xE8, MASKALPHA = 0xE9,
};

static void writeFile(const char *name, const void *p, int bytes) {
	char path[96];
	snprintf(path, sizeof(path), "host0:/line/%s", name);
	SceUID fd = sceIoOpen(path, PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	if (fd >= 0) {
		sceIoWrite(fd, p, bytes);
		sceIoClose(fd);
	}
}

// End points inside the cell, 1 pixel from its edges (in 1/16 pixel).
static void endpoints(const char *set, int *x0, int *y0, int *x1, int *y1) {
	int lo = 16, hix = (CW - 1) * 16, hiy = (CH - 1) * 16;
	if (!strcmp(set, "rand") || !strcmp(set, "aa")) {
		*x0 = irand(lo, hix); *y0 = irand(lo, hiy); *x1 = irand(lo, hix); *y1 = irand(lo, hiy);
	} else if (!strcmp(set, "half")) {
		*x0 = irand(2, 2 * (CW - 1)) * 8; *y0 = irand(2, 2 * (CH - 1)) * 8;
		*x1 = irand(2, 2 * (CW - 1)) * 8; *y1 = irand(2, 2 * (CH - 1)) * 8;
	} else if (!strcmp(set, "short")) {
		*x0 = irand(48, hix - 48); *y0 = irand(48, hiy - 48);
		*x1 = *x0 + irand(-32, 32); *y1 = *y0 + irand(-32, 32);
	} else {
		// slope within 1/16 of 1 either way, or exactly 1
		*x0 = irand(lo, hix / 2); *y0 = irand(lo, hiy / 2);
		int len = irand(16, 12 * 16);
		int d = irand(-2, 2);
		int sx = (next() & 1) ? 1 : -1, sy = (next() & 1) ? 1 : -1;
		*x1 = *x0 + len; *y1 = *y0 + len + d;
		if (*y1 > hiy) *y1 = hiy;
		if (sx < 0) { int t = *x0; *x0 = *x1; *x1 = t; }
		if (sy < 0) { int t = *y0; *y0 = *y1; *y1 = t; }
	}
}

static void frame(const char *set, int f) {
	cmd = list;
	emit(CLIPENABLE, 0); emit(CULLENABLE, 0); emit(TEXENABLE, 0); emit(FOGENABLE, 0);
	emit(DITHERENABLE, 0); emit(BLENDENABLE, 0); emit(ALPHATEST, 0); emit(ZTESTEN, 0);
	int aa = !strcmp(set, "aa");
	emit(STENCILTEST, 0); emit(ANTIALIAS, aa); emit(COLORTEST, 0); emit(LOGICOP, 0); emit(LIGHTING, 0);
	if (aa) {
		emit(BLENDENABLE, 1);
		emit(BLENDMODE, 2 | (3 << 4));
	}
	emit(SHADEMODE, 0); emit(MASKRGB, 0); emit(MASKALPHA, 0); emit(MINZ, 0); emit(MAXZ, 0xFFFF);
	emit(VTYPE, (1 << 23) | (7 << 2) | (3 << 7));
	for (int c = 0; c < CELLS; c++) {
		int cx = (c % 16) * CW * 16, cy = (c / 16) * CH * 16;
		int x0, y0, x1, y1;
		endpoints(set, &x0, &y0, &x1, &y1);
		Vert *v = &verts[c * 2];
		unsigned int col = 0xFFFFFFFF;
		if (aa)
			col = 0x00FFFFFF | ((unsigned int)irand(0, 255) << 24);
		cellColor[c] = col;
		v[0].color = col; v[0].x = (cx + x0) / 16.0f; v[0].y = (cy + y0) / 16.0f; v[0].z = 0;
		v[1].color = col; v[1].x = (cx + x1) / 16.0f; v[1].y = (cy + y1) / 16.0f; v[1].z = 0;
		inputs[c * 4] = cx + x0; inputs[c * 4 + 1] = cy + y0; inputs[c * 4 + 2] = cx + x1; inputs[c * 4 + 3] = cy + y1;
		unsigned int a = (unsigned int)v;
		emit(BASE, (a >> 8) & 0x0F0000);
		emit(VADDR, a & 0xFFFFFF);
		emit(PRIM, (1 << 16) | 2);
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
	snprintf(file, sizeof(file), "%s_%d.bin", set, f);
	writeFile(file, colors, sizeof(colors));
	snprintf(file, sizeof(file), "%s_%d_in.bin", set, f);
	writeFile(file, inputs, sizeof(inputs));
	if (aa) {
		snprintf(file, sizeof(file), "%s_%d_col.bin", set, f);
		writeFile(file, cellColor, sizeof(cellColor));
	}
	scePowerTick(PSP_POWER_TICK_ALL);
}

int main(int argc, char *argv[]) {
	sceIoMkdir("host0:/line", 0777);
	SceUID logFd = sceIoOpen("host0:/__testoutput.txt", PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);

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

	static const char *sets[5] = { "rand", "half", "short", "diag", "aa" };
	for (int s = 0; s < 5; s++)
		for (int f = 0; f < FRAMES; f++)
			frame(sets[s], f);

	if (logFd >= 0) {
		sceIoWrite(logFd, "line: 5 sets\n", 13);
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
