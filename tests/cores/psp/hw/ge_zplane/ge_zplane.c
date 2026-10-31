// Records how the GE interpolates depth over a triangle: through-mode
// triangles with steep depth ramps, 16 a frame in a 4 x 4 grid of 120 x 68
// pixel cells, depth test always passing and depth writes on; the depth
// buffer is read back through VRAM's linear depth view
// (host0:/zplane/frame_<n>.bin, 272 rows of 512 16-bit values, cleared to
// 0x1234 outside the triangles) and the triangles go to
// host0:/zplane/tris.bin (per triangle three vertices of x, y in 1/16 pixel
// and z, 32-bit little endian each).
//
// Each triangle has a unique leftmost vertex near its cell's left edge, the
// others to the right and below, random 1/16 pixel positions (so the areas
// take many mantissas) and depths rising by 100 to 300 a pixel. Then as many
// frames of variants (var_<n>.bin, vtris.bin): random triangles, each drawn
// eight ways (vertex order rotated and reversed, depths flipped, mirrored in
// x and in y), to find which vertex the depth plane starts from; and frames
// of triangles with shared coordinates (tie_<n>.bin, ttris.bin): right
// angles with axis-aligned legs, two vertices on a row or on a column.

#include <pspkernel.h>
#include <pspge.h>
#include <pspgu.h>
#include <psppower.h>
#include <stdio.h>
#include <string.h>

PSP_MODULE_INFO("GEZPLANE", 0, 1, 0);
PSP_MAIN_THREAD_ATTR(PSP_THREAD_ATTR_USER | PSP_THREAD_ATTR_VFPU);
PSP_HEAP_SIZE_KB(1024);

#define W 480
#define H 272
#define ZBUF 0x88000
#define CELLS 16
#define FRAMES 64

typedef struct {
	unsigned int color;
	float x, y, z;
} Vertex;

static unsigned int __attribute__((aligned(64))) setupList[4096];
static unsigned int __attribute__((aligned(64))) list[4096];
static Vertex __attribute__((aligned(64))) verts[CELLS * 3];
static unsigned short __attribute__((aligned(64))) depth[512 * H];
static int tris[FRAMES * CELLS * 9];

static unsigned int *cmd;
static unsigned int rng = 0x2545F491;

static unsigned int next(void) {
	rng ^= rng << 13;
	rng ^= rng >> 17;
	rng ^= rng << 5;
	return rng;
}

// Uniform in [lo, hi].
static int irand(int lo, int hi) {
	return lo + (int)(next() % (unsigned int)(hi - lo + 1));
}

static void emit(unsigned int c, unsigned int arg) {
	*cmd++ = (c << 24) | (arg & 0xFFFFFF);
}

enum {
	VADDR = 0x01, PRIM = 0x04, BASE = 0x10, VTYPE = 0x12, LIGHTING = 0x17, CLIPENABLE = 0x1C, CULLENABLE = 0x1D,
	TEXENABLE = 0x1E, FOGENABLE = 0x1F, DITHERENABLE = 0x20, BLENDENABLE = 0x21, ALPHATEST = 0x22, ZTESTEN = 0x23,
	STENCILTEST = 0x24, COLORTEST = 0x27, LOGICOP = 0x28, SHADEMODE = 0x50,
	ZBUFPTR = 0x9E, ZBUFWIDTH = 0x9F, MINZ = 0xD6, MAXZ = 0xD7, ZTEST = 0xDE, ZWRITEDISABLE = 0xE7,
	MASKRGB = 0xE8, MASKALPHA = 0xE9,
};

static void writeFile(const char *name, const void *p, int bytes) {
	char path[96];
	snprintf(path, sizeof(path), "host0:/zplane/%s", name);
	SceUID fd = sceIoOpen(path, PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	if (fd >= 0) {
		sceIoWrite(fd, p, bytes);
		sceIoClose(fd);
	}
}

// Variants of one base triangle (positions relative to its cell): the
// vertex order rotated or reversed, the depths flipped (40000 - z), the
// positions mirrored in x or y.
static void variant(int v, int bx[3], int by[3], int bz[3], int xs[3], int ys[3], int zs[3]) {
	static const int order[8][3] = { { 0, 1, 2 }, { 1, 2, 0 }, { 2, 0, 1 }, { 0, 2, 1 }, { 0, 1, 2 }, { 1, 2, 0 }, { 0, 1, 2 }, { 0, 1, 2 } };
	for (int k = 0; k < 3; k++) {
		int s = order[v][k];
		xs[k] = bx[s];
		ys[k] = by[s];
		zs[k] = bz[s];
		if (v == 4 || v == 5)
			zs[k] = 40000 - zs[k];
		if (v == 6)
			xs[k] = 1904 - xs[k];
		if (v == 7)
			ys[k] = 1072 - ys[k];
	}
}

static int variants;

// Triangles with shared coordinates: a right angle with axis-aligned legs
// (type 0), two vertices on one row (1) or on one column (2); the vertex
// order shuffled.
static void tieTriangle(int xs[3], int ys[3], int zs[3]) {
	int type = next() % 3;
	int px[3], py[3];
	if (type == 0) {
		int cx = irand(400, 1500), cy = irand(200, 870);
		int w = irand(200, 380), h = irand(150, 190);
		if (next() & 1) w = -w;
		if (next() & 1) h = -h;
		px[0] = cx; py[0] = cy; px[1] = cx + w; py[1] = cy; px[2] = cx; py[2] = cy + h;
	} else if (type == 1) {
		int y = irand(16, 1056), y2 = irand(16, 1056);
		while (y2 > y - 160 && y2 < y + 160)
			y2 = irand(16, 1056);
		px[0] = irand(16, 800); px[1] = irand(1000, 1888); py[0] = py[1] = y;
		px[2] = irand(16, 1888); py[2] = y2;
	} else {
		int x = irand(16, 1888), x2 = irand(16, 1888);
		while (x2 > x - 300 && x2 < x + 300)
			x2 = irand(16, 1888);
		py[0] = irand(16, 450); py[1] = irand(620, 1056); px[0] = px[1] = x;
		py[2] = irand(16, 1056); px[2] = x2;
	}
	int perm = next() % 6;
	static const int P[6][3] = { { 0, 1, 2 }, { 0, 2, 1 }, { 1, 0, 2 }, { 1, 2, 0 }, { 2, 0, 1 }, { 2, 1, 0 } };
	for (int k = 0; k < 3; k++) {
		xs[k] = px[P[perm][k]];
		ys[k] = py[P[perm][k]];
		zs[k] = irand(2000, 38000);
	}
}

static void frame(int f) {
	int bx[3], by[3], bz[3];
	for (int c = 0; c < CELLS; c++) {
		if (variants == 2) {
			int cx = (c % 4) * 120 * 16, cy = (c / 4) * 68 * 16;
			int xs[3], ys[3], zs[3];
			tieTriangle(xs, ys, zs);
			int *t = &tris[(f * CELLS + c) * 9];
			for (int v = 0; v < 3; v++) {
				Vertex *vx = &verts[c * 3 + v];
				vx->color = 0xFF00FF00;
				vx->x = (cx + xs[v]) / 16.0f;
				vx->y = (cy + ys[v]) / 16.0f;
				vx->z = (float)zs[v];
				t[v * 3] = cx + xs[v];
				t[v * 3 + 1] = cy + ys[v];
				t[v * 3 + 2] = zs[v];
			}
			continue;
		}
		if (variants) {
			if ((c & 7) == 0) {
				// A new base triangle: random vertices over the cell.
				for (int k = 0; k < 3; k++) {
					bx[k] = irand(16, 1888);
					by[k] = irand(16, 1056);
					bz[k] = irand(2000, 38000);
				}
			}
			int cx = (c % 4) * 120 * 16, cy = (c / 4) * 68 * 16;
			int xs[3], ys[3], zs[3];
			variant(c & 7, bx, by, bz, xs, ys, zs);
			int *t = &tris[(f * CELLS + c) * 9];
			for (int v = 0; v < 3; v++) {
				Vertex *vx = &verts[c * 3 + v];
				vx->color = 0xFF00FF00;
				vx->x = (cx + xs[v]) / 16.0f;
				vx->y = (cy + ys[v]) / 16.0f;
				vx->z = (float)zs[v];
				t[v * 3] = cx + xs[v];
				t[v * 3 + 1] = cy + ys[v];
				t[v * 3 + 2] = zs[v];
			}
			continue;
		}
		int cx = (c % 4) * 120 * 16, cy = (c / 4) * 68 * 16;
		int *t = &tris[(f * CELLS + c) * 9];
		// Leftmost vertex near the left edge, mid height; one to the right
		// (above or below), one below to the right of the first.
		int x0 = cx + irand(8, 120), y0 = cy + irand(200, 860);
		int x1 = cx + irand(1500, 1900), y1 = cy + irand(16, 1060);
		int x2 = x0 + irand(40, 1200), y2 = cy + irand(16, 1060);
		// Keep the third vertex on the other side of the first edge from the
		// cell's middle, so the triangle is not thin.
		if ((y1 < y0) == (y2 < y0)) {
			y2 = 2 * y0 - y2;
			if (y2 < cy + 16) y2 = cy + 16;
			if (y2 > cy + 1072) y2 = cy + 1072;
		}
		// Depths: the leftmost lowish, rising 100..300 a pixel to the right
		// and -150..150 a pixel downwards, all within 0..65535.
		int z0 = irand(2000, 6000);
		int gx = irand(100, 300), gy = irand(-150, 150);
		int z1 = z0 + gx * (x1 - x0) / 16 + gy * (y1 - y0) / 16;
		int z2 = z0 + gx * (x2 - x0) / 16 + gy * (y2 - y0) / 16;
		z1 += irand(-300, 300);
		z2 += irand(-300, 300);
		if (z1 < 0) z1 = 0;
		if (z1 > 65535) z1 = 65535;
		if (z2 < 0) z2 = 0;
		if (z2 > 65535) z2 = 65535;
		int xs[3] = { x0, x1, x2 }, ys[3] = { y0, y1, y2 }, zs[3] = { z0, z1, z2 };
		for (int v = 0; v < 3; v++) {
			Vertex *vx = &verts[c * 3 + v];
			vx->color = 0xFF00FF00;
			vx->x = xs[v] / 16.0f;
			vx->y = ys[v] / 16.0f;
			vx->z = (float)zs[v];
			t[v * 3] = xs[v];
			t[v * 3 + 1] = ys[v];
			t[v * 3 + 2] = zs[v];
		}
	}
	sceKernelDcacheWritebackAll();

	sceGuStart(GU_DIRECT, setupList);
	sceGuClearColor(0);
	sceGuClearDepth(0x1234);
	sceGuClear(GU_COLOR_BUFFER_BIT | GU_DEPTH_BUFFER_BIT);
	sceGuFinish();
	sceGuSync(0, 0);

	cmd = list;
	emit(CLIPENABLE, 0); emit(CULLENABLE, 0); emit(TEXENABLE, 0); emit(FOGENABLE, 0);
	emit(DITHERENABLE, 0); emit(BLENDENABLE, 0); emit(ALPHATEST, 0); emit(STENCILTEST, 0);
	emit(COLORTEST, 0); emit(LOGICOP, 0); emit(LIGHTING, 0); emit(SHADEMODE, 1);
	emit(MASKRGB, 0); emit(MASKALPHA, 0);
	emit(ZTESTEN, 1); emit(ZTEST, 1); emit(ZWRITEDISABLE, 0);
	emit(ZBUFPTR, ZBUF & 0xFFFFFF); emit(ZBUFWIDTH, 512);
	emit(MINZ, 0); emit(MAXZ, 0xFFFF);
	emit(VTYPE, (1 << 23) | (3 << 7) | (7 << 2));
	unsigned int a = (unsigned int)verts;
	emit(BASE, (a >> 8) & 0x0F0000);
	emit(VADDR, a & 0xFFFFFF);
	emit(PRIM, (3 << 16) | (CELLS * 3));
	emit(0x0F, 0);
	emit(0x0C, 0);
	sceKernelDcacheWritebackAll();
	int id = sceGeListEnQueue(list, cmd, -1, NULL);
	sceGeListSync(id, 0);

	const volatile unsigned short *src = (const volatile unsigned short *)(0x44000000 + 0x600000 + ZBUF);
	for (int i = 0; i < 512 * H; i++)
		depth[i] = src[i];
	char file[64];
	snprintf(file, sizeof(file), variants == 2 ? "tie_%03d.bin" : variants ? "var_%03d.bin" : "frame_%03d.bin", f);
	writeFile(file, depth, sizeof(depth));
	scePowerTick(PSP_POWER_TICK_ALL);
}

int main(int argc, char *argv[]) {
	sceIoMkdir("host0:/zplane", 0777);
	SceUID logFd = sceIoOpen("host0:/__testoutput.txt", PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);

	sceGuInit();
	sceGuStart(GU_DIRECT, setupList);
	sceGuDrawBuffer(GU_PSM_8888, (void *)0, 512);
	sceGuDispBuffer(W, H, (void *)0, 512);
	sceGuDepthBuffer((void *)ZBUF, 512);
	sceGuOffset(2048 - 240, 2048 - 136);
	sceGuViewport(2048, 2048, W, H);
	sceGuScissor(0, 0, W, H);
	sceGuEnable(GU_SCISSOR_TEST);
	sceGuFinish();
	sceGuSync(0, 0);
	sceGuDisplay(1);

	for (int f = 0; f < FRAMES; f++)
		frame(f);
	writeFile("tris.bin", tris, sizeof(tris));
	variants = 1;
	for (int f = 0; f < FRAMES; f++)
		frame(f);
	writeFile("vtris.bin", tris, sizeof(tris));
	variants = 2;
	for (int f = 0; f < FRAMES; f++)
		frame(f);
	writeFile("ttris.bin", tris, sizeof(tris));

	char line[64];
	snprintf(line, sizeof(line), "zplane: %d frames\n", FRAMES);
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
