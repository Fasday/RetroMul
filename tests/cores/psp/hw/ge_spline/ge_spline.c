// Records how the GE evaluates spline patches: SPLINE with 4..7 x 4..7
// control points, random edge types and divisions, drawn as points
// (PATCHPRIMITIVE 2), 16 a frame in a 4 x 4 grid of 120 x 68 pixel cells.
// Every row of control points has the same x and every column the same y,
// rising with the index, so the evaluated points form a grid whose columns
// and rows sort by x and y; their depth and colour are the evaluated z and
// colour. Depth test always passing, depth writes on; the colour buffer
// (host0:/spline/<set>_<n>_c.bin, 272 rows of 512 8888 pixels) and the depth
// buffer through VRAM's linear view (<set>_<n>_z.bin, 16-bit) are read back,
// the patches to <set>_<n>_in.bin: per cell u and v counts, u and v edge
// types, u and v divisions, then 64 control points (row by row, u fastest)
// of z (a 32-bit float's bits) and 64 colours.
//
// Sets: "one" (one control point at z 65535, colour white, the rest 0),
// "rand" (random z 0..65535 and colours), "big" (the vertices in 3D:
// identity matrices, depth scale and centre 32767.5, z in -1..1 at random
// exponents and signs).

#include <pspkernel.h>
#include <pspge.h>
#include <pspgu.h>
#include <psppower.h>
#include <stdio.h>
#include <string.h>

PSP_MODULE_INFO("GESPLINE", 0, 1, 0);
PSP_MAIN_THREAD_ATTR(PSP_THREAD_ATTR_USER | PSP_THREAD_ATTR_VFPU);
PSP_HEAP_SIZE_KB(1024);

#define W 480
#define H 272
#define ZBUF 0x88000
#define CW 120
#define CH 68
#define CELLS 16
#define FRAMES 16

typedef struct {
	unsigned int color;
	float x, y, z;
} Vertex;

typedef struct {
	int ucount, vcount, utype, vtype, udiv, vdiv;
	unsigned int z[64];
	unsigned int color[64];
} Cell;

static unsigned int __attribute__((aligned(64))) setupList[4096];
static unsigned int __attribute__((aligned(64))) list[8192];
static Vertex __attribute__((aligned(64))) verts[CELLS * 64];
static unsigned int __attribute__((aligned(64))) colors[512 * H];
static unsigned short __attribute__((aligned(64))) depth[512 * H];
static Cell cells[CELLS];

static unsigned int *cmd;
static unsigned int rng = 0x3C6EF372;

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

static unsigned int f24(float f) {
	union { float f; unsigned int u; } v;
	v.f = f;
	return v.u >> 8;
}

enum {
	VADDR = 0x01, SPLINE = 0x06, BASE = 0x10, VTYPE = 0x12, LIGHTING = 0x17, CLIPENABLE = 0x1C, CULLENABLE = 0x1D,
	TEXENABLE = 0x1E, FOGENABLE = 0x1F, DITHERENABLE = 0x20, BLENDENABLE = 0x21, ALPHATEST = 0x22, ZTESTEN = 0x23,
	STENCILTEST = 0x24, ANTIALIAS = 0x25, COLORTEST = 0x27, LOGICOP = 0x28, PATCHDIVISION = 0x36, PATCHPRIMITIVE = 0x37,
	WORLDNUM = 0x3A, WORLDDATA = 0x3B, VIEWNUM = 0x3C, VIEWDATA = 0x3D, PROJNUM = 0x3E, PROJDATA = 0x3F,
	VPXS = 0x42, VPYS = 0x43, VPZS = 0x44, VPXC = 0x45, VPYC = 0x46, VPZC = 0x47, SHADEMODE = 0x50,
	OFFSETX = 0x4C, OFFSETY = 0x4D,
	ZBUFPTR = 0x9E, ZBUFWIDTH = 0x9F, MINZ = 0xD6, MAXZ = 0xD7, ZTEST = 0xDE, ZWRITEDISABLE = 0xE7,
	MASKRGB = 0xE8, MASKALPHA = 0xE9,
};

static void writeFile(const char *name, const void *p, int bytes) {
	char path[96];
	snprintf(path, sizeof(path), "host0:/spline/%s", name);
	SceUID fd = sceIoOpen(path, PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	if (fd >= 0) {
		sceIoWrite(fd, p, bytes);
		sceIoClose(fd);
	}
}

static float randomZ(const char *set) {
	if (!strcmp(set, "rand"))
		return (float)irand(0, 65535);
	float m = (float)irand(0x800000, 0xFFFFFF) / (float)0x1000000;
	int e = irand(0, 12);
	while (e--)
		m *= 0.5f;
	return (next() & 1) ? -m : m;
}

// Control point positions along an axis: rising, spread over Span pixels.
static float axisPos(int k, int count, float span) {
	return span * k / (count - 1);
}

static void frame(const char *set, int f) {
	int is3d = !strcmp(set, "big");
	for (int c = 0; c < CELLS; c++) {
		Cell *cl = &cells[c];
		int cx = (c % 4) * CW, cy = (c / 4) * CH;
		cl->ucount = irand(4, 7);
		cl->vcount = irand(4, 7);
		cl->utype = irand(0, 3);
		cl->vtype = irand(0, 3);
		// Up to 32 points across and 16 down.
		int us = cl->ucount - 3, vs = cl->vcount - 3;
		cl->udiv = irand(1, 32 / us > 8 ? 8 : 32 / us);
		cl->vdiv = irand(1, 16 / vs > 6 ? 6 : 16 / vs);
		int n = cl->ucount * cl->vcount;
		int one = irand(0, n - 1);
		for (int k = 0; k < n; k++) {
			int i = k % cl->ucount, j = k / cl->ucount;
			Vertex *v = &verts[c * 64 + k];
			float z;
			unsigned int col;
			if (!strcmp(set, "one")) {
				z = k == one ? 65535.0f : 0.0f;
				col = k == one ? 0xFFFFFFFF : 0xFF000000;
			} else {
				z = randomZ(set);
				col = next();
			}
			float x = cx + 4.5f + axisPos(i, cl->ucount, CW - 9);
			float y = cy + 4.5f + axisPos(j, cl->vcount, CH - 9);
			if (is3d) {
				x = (x - 240.0f) / 240.0f;
				y = (136.0f - y) / 136.0f;
			}
			v->color = col; v->x = x; v->y = y; v->z = z;
			union { float f; unsigned int u; } zb;
			zb.f = z;
			cl->z[k] = zb.u;
			cl->color[k] = col;
		}
	}
	sceKernelDcacheWritebackAll();

	sceGuStart(GU_DIRECT, setupList);
	sceGuClearColor(0);
	sceGuClearDepth(0);
	sceGuClear(GU_COLOR_BUFFER_BIT | GU_DEPTH_BUFFER_BIT);
	sceGuFinish();
	sceGuSync(0, 0);

	cmd = list;
	emit(CLIPENABLE, 0); emit(CULLENABLE, 0); emit(TEXENABLE, 0); emit(FOGENABLE, 0);
	emit(DITHERENABLE, 0); emit(BLENDENABLE, 0); emit(ALPHATEST, 0); emit(STENCILTEST, 0); emit(ANTIALIAS, 0);
	emit(COLORTEST, 0); emit(LOGICOP, 0); emit(LIGHTING, 0); emit(SHADEMODE, 1);
	emit(MASKRGB, 0); emit(MASKALPHA, 0);
	emit(ZTESTEN, 1); emit(ZTEST, 1); emit(ZWRITEDISABLE, 0);
	emit(ZBUFPTR, ZBUF & 0xFFFFFF); emit(ZBUFWIDTH, 512);
	emit(MINZ, 0); emit(MAXZ, 0xFFFF);
	emit(PATCHPRIMITIVE, 2);
	if (is3d) {
		emit(WORLDNUM, 0);
		for (int k = 0; k < 12; k++) emit(WORLDDATA, (k % 4 == 0 && k < 9) ? f24(1.0f) : 0);
		emit(VIEWNUM, 0);
		for (int k = 0; k < 12; k++) emit(VIEWDATA, (k % 4 == 0 && k < 9) ? f24(1.0f) : 0);
		emit(PROJNUM, 0);
		for (int k = 0; k < 16; k++) emit(PROJDATA, (k % 5 == 0) ? f24(1.0f) : 0);
		emit(VPXS, f24(240.0f)); emit(VPYS, f24(-136.0f)); emit(VPZS, f24(32767.5f));
		emit(VPXC, f24(2048.0f)); emit(VPYC, f24(2048.0f)); emit(VPZC, f24(32767.5f));
		emit(OFFSETX, (2048 - 240) << 4); emit(OFFSETY, (2048 - 136) << 4);
		emit(VTYPE, (3 << 7) | (7 << 2));
	} else {
		emit(VTYPE, (1 << 23) | (3 << 7) | (7 << 2));
	}
	for (int c = 0; c < CELLS; c++) {
		Cell *cl = &cells[c];
		unsigned int a = (unsigned int)&verts[c * 64];
		emit(PATCHDIVISION, cl->udiv | (cl->vdiv << 8));
		emit(BASE, (a >> 8) & 0x0F0000);
		emit(VADDR, a & 0xFFFFFF);
		emit(SPLINE, cl->ucount | (cl->vcount << 8) | (cl->utype << 16) | (cl->vtype << 18));
	}
	emit(0x0F, 0);
	emit(0x0C, 0);
	sceKernelDcacheWritebackAll();
	int id = sceGeListEnQueue(list, cmd, -1, NULL);
	sceGeListSync(id, 0);

	const volatile unsigned int *srcc = (const volatile unsigned int *)0x44000000;
	for (int i = 0; i < 512 * H; i++)
		colors[i] = srcc[i];
	const volatile unsigned short *src = (const volatile unsigned short *)(0x44000000 + 0x600000 + ZBUF);
	for (int i = 0; i < 512 * H; i++)
		depth[i] = src[i];
	char file[64];
	snprintf(file, sizeof(file), "%s_%d_c.bin", set, f);
	writeFile(file, colors, sizeof(colors));
	snprintf(file, sizeof(file), "%s_%d_z.bin", set, f);
	writeFile(file, depth, sizeof(depth));
	snprintf(file, sizeof(file), "%s_%d_in.bin", set, f);
	writeFile(file, cells, sizeof(cells));
	scePowerTick(PSP_POWER_TICK_ALL);
}

int main(int argc, char *argv[]) {
	sceIoMkdir("host0:/spline", 0777);
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

	static const char *sets[3] = { "one", "rand", "big" };
	for (int s = 0; s < 3; s++)
		for (int f = 0; f < FRAMES; f++)
			frame(sets[s], f);

	if (logFd >= 0) {
		sceIoWrite(logFd, "spline: 3 sets\n", 15);
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
