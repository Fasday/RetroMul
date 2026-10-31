// Records how the GE evaluates Bezier patches: 4 x 4 control point patches
// drawn as points (PATCHPRIMITIVE 2), 32 a frame in an 8 x 4 grid of 60 x 68
// pixel cells, random divisions 1..16 in u and v. The control points' x and
// y put every evaluated point on a pixel centre (x = cell + 4.5 + step * i),
// so a point's pixel tells which (i, j) it is; its depth and colour are the
// evaluated z and colour. Depth test always passing, depth writes on; the
// colour buffer (host0:/patch/<set>_<n>_c.bin, 272 rows of 512 8888 pixels)
// and the depth buffer through VRAM's linear view (<set>_<n>_z.bin, 16-bit)
// are read back, the patches to <set>_<n>_in.bin: per cell u and v
// divisions, u and v steps in pixels, then 16 control points of z (as a
// 32-bit float's bits) and colour.
//
// Sets: "one" (one control point at z 65535, colour white, the rest 0: the
// weights), "rand" (random z 0..65535, random colours), "big" (through
// mode, the vertex given in 3D: identity matrices, a viewport with depth
// scale and centre 32767.5, z in -1..1 at random exponents and signs; x and
// y as in through mode, mapped back).

#include <pspkernel.h>
#include <pspge.h>
#include <pspgu.h>
#include <psppower.h>
#include <stdio.h>
#include <string.h>

PSP_MODULE_INFO("GEPATCH", 0, 1, 0);
PSP_MAIN_THREAD_ATTR(PSP_THREAD_ATTR_USER | PSP_THREAD_ATTR_VFPU);
PSP_HEAP_SIZE_KB(1024);

#define W 480
#define H 272
#define ZBUF 0x88000
#define CW 60
#define CH 68
#define CELLS 32
#define FRAMES 8

typedef struct {
	unsigned int color;
	float x, y, z;
} Vertex;

typedef struct {
	int udiv, vdiv, us, vs;
	unsigned int z[16];
	unsigned int color[16];
} Cell;

static unsigned int __attribute__((aligned(64))) setupList[4096];
static unsigned int __attribute__((aligned(64))) list[8192];
static Vertex __attribute__((aligned(64))) verts[CELLS * 16];
static unsigned int __attribute__((aligned(64))) colors[512 * H];
static unsigned short __attribute__((aligned(64))) depth[512 * H];
static Cell cells[CELLS];

static unsigned int *cmd;
static unsigned int rng = 0x6C078965;

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
	VADDR = 0x01, BEZIER = 0x05, BASE = 0x10, VTYPE = 0x12, LIGHTING = 0x17, CLIPENABLE = 0x1C, CULLENABLE = 0x1D,
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
	snprintf(path, sizeof(path), "host0:/patch/%s", name);
	SceUID fd = sceIoOpen(path, PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	if (fd >= 0) {
		sceIoWrite(fd, p, bytes);
		sceIoClose(fd);
	}
}

static float randomZ(const char *set) {
	if (!strcmp(set, "rand"))
		return (float)irand(0, 65535);
	// In -1..1: a random mantissa at exponent 0 down to -12, random sign.
	float m = (float)irand(0x800000, 0xFFFFFF) / (float)0x1000000;
	int e = irand(0, 12);
	while (e--)
		m *= 0.5f;
	return (next() & 1) ? -m : m;
}

static void frame(const char *set, int f) {
	int is3d = !strcmp(set, "big");
	for (int c = 0; c < CELLS; c++) {
		Cell *cl = &cells[c];
		int cx = (c % 8) * CW, cy = (c / 8) * CH;
		cl->udiv = irand(1, 16);
		cl->vdiv = irand(1, 16);
		cl->us = (CW - 8) / cl->udiv;
		cl->vs = (CH - 8) / cl->vdiv;
		int one = irand(0, 15);
		for (int k = 0; k < 16; k++) {
			int i = k & 3, j = k >> 2;
			Vertex *v = &verts[c * 16 + k];
			float z;
			unsigned int col;
			if (!strcmp(set, "one")) {
				z = k == one ? 65535.0f : 0.0f;
				col = k == one ? 0xFFFFFFFF : 0xFF000000;
			} else {
				z = randomZ(set);
				col = next();
			}
			float x = cx + 4.5f + cl->us * cl->udiv * i / 3.0f;
			float y = cy + 4.5f + cl->vs * cl->vdiv * j / 3.0f;
			if (is3d) {
				// Screen = 240 + 240 x, 136 - 136 y.
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
		// 4 rows of 3: the identity's ones at 0, 4 and 8.
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
		unsigned int a = (unsigned int)&verts[c * 16];
		emit(PATCHDIVISION, cells[c].udiv | (cells[c].vdiv << 8));
		emit(BASE, (a >> 8) & 0x0F0000);
		emit(VADDR, a & 0xFFFFFF);
		emit(BEZIER, 4 | (4 << 8));
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
	sceIoMkdir("host0:/patch", 0777);
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
		sceIoWrite(logFd, "patch: 3 sets\n", 14);
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
