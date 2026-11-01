// Records the depth of triangles whose vertices' depths after the viewport
// lie outside 0..65535 with depth clamping on (CLIPENABLE): orthographic
// (w = 1), no vertex beyond the near plane. Sets: "in" (z in [-1, 1], the
// viewport's depth scale 60000 around 32768, so every vertex inside the
// planes, depths -27232..92768) and "far" (z in [-0.5, 1.5], scale and
// centre 32767.5: vertices beyond the far plane). 16 random triangles a
// frame, one per 120 x 68 cell, depth test always passing and written; the
// depth buffer goes to host0:/zclamp/<set>_<n>.bin (272 rows of 512 16-bit
// values), the triangles to <set>_<n>_in.bin (per vertex x, y, z float).

#include <pspkernel.h>
#include <pspge.h>
#include <pspgu.h>
#include <psppower.h>
#include <stdio.h>
#include <string.h>

PSP_MODULE_INFO("GEZCLAMP", 0, 1, 0);
PSP_MAIN_THREAD_ATTR(PSP_THREAD_ATTR_USER | PSP_THREAD_ATTR_VFPU);
PSP_HEAP_SIZE_KB(2048);

#define W 480
#define H 272
#define CELLS 16
#define FRAMES 16

typedef struct {
	float x, y, z;
} Vertex;

static unsigned int __attribute__((aligned(64))) setupList[4096];
static unsigned int __attribute__((aligned(64))) list[4096];
static Vertex __attribute__((aligned(64))) verts[CELLS * 3];
static unsigned short __attribute__((aligned(64))) depth[512 * H];
static float inputs[CELLS * 3 * 3];

static unsigned int *cmd;
static unsigned int rng = 0x5A17C3E9;

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
	SHADEMODE = 0x50, MATAMBIENT = 0x55, MATALPHA = 0x58, ZTEST = 0xDE, ZWRITEDISABLE = 0xE7,
	MINZ = 0xD6, MAXZ = 0xD7, MASKRGB = 0xE8, MASKALPHA = 0xE9,
};

static void writeFile(const char *name, const void *p, int bytes) {
	char path[96];
	snprintf(path, sizeof(path), "host0:/zclamp/%s", name);
	SceUID fd = sceIoOpen(path, PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	if (fd >= 0) {
		sceIoWrite(fd, p, bytes);
		sceIoClose(fd);
	}
}

static void frame(int far, int f) {
	for (int c = 0; c < CELLS; c++) {
		int cx = (c % 4) * 120, cy = (c / 4) * 68;
		for (int i = 0; i < 3; i++) {
			Vertex *v = &verts[c * 3 + i];
			float sx = cx + frand(2, 118), sy = cy + frand(2, 66);
			float z = far ? frand(-0.5f, 1.5f) : frand(-1.0f, 1.0f);
			float *in = &inputs[(c * 3 + i) * 3];
			in[0] = sx; in[1] = sy; in[2] = z;
			v->x = (sx - 240.0f) / 240.0f;
			v->y = (136.0f - sy) / 136.0f;
			v->z = z;
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
	emit(CLIPENABLE, 1); emit(CULLENABLE, 0); emit(FOGENABLE, 0); emit(TEXENABLE, 0);
	emit(DITHERENABLE, 0); emit(BLENDENABLE, 0); emit(ALPHATEST, 0);
	emit(STENCILTEST, 0); emit(ANTIALIAS, 0); emit(COLORTEST, 0); emit(LOGICOP, 0); emit(LIGHTING, 0);
	emit(SHADEMODE, 0); emit(MASKRGB, 0); emit(MASKALPHA, 0); emit(MINZ, 0); emit(MAXZ, 0xFFFF);
	emit(ZTESTEN, 1); emit(ZTEST, 1); emit(ZWRITEDISABLE, 0);
	emit(MATAMBIENT, 0xFFFFFF); emit(MATALPHA, 0xFF);
	emit(WORLDNUM, 0);
	for (int k = 0; k < 12; k++) emit(WORLDDATA, (k % 4 == 0 && k < 9) ? f24(1.0f) : 0);
	emit(VIEWNUM, 0);
	for (int k = 0; k < 12; k++) emit(VIEWDATA, (k % 4 == 0 && k < 9) ? f24(1.0f) : 0);
	emit(PROJNUM, 0);
	for (int k = 0; k < 16; k++) emit(PROJDATA, (k == 0 || k == 5 || k == 10 || k == 15) ? f24(1.0f) : 0);
	float zs = far ? 32767.5f : 60000.0f, zc = far ? 32767.5f : 32768.0f;
	emit(VPXS, f24(240.0f)); emit(VPYS, f24(-136.0f)); emit(VPZS, f24(zs));
	emit(VPXC, f24(2048.0f)); emit(VPYC, f24(2048.0f)); emit(VPZC, f24(zc));
	emit(OFFSETX, (2048 - 240) << 4); emit(OFFSETY, (2048 - 136) << 4);
	emit(VTYPE, 3 << 7);
	unsigned int a = (unsigned int)verts;
	emit(BASE, (a >> 8) & 0x0F0000);
	emit(VADDR, a & 0xFFFFFF);
	emit(PRIM, (3 << 16) | (CELLS * 3));
	emit(0x0F, 0);
	emit(0x0C, 0);
	sceKernelDcacheWritebackAll();
	int id = sceGeListEnQueue(list, cmd, -1, NULL);
	sceGeListSync(id, 0);

	const volatile unsigned short *src = (const volatile unsigned short *)0x44088000;
	for (int i = 0; i < 512 * H; i++)
		depth[i] = src[i];
	char file[64];
	snprintf(file, sizeof(file), "%s_%d.bin", far ? "far" : "in", f);
	writeFile(file, depth, sizeof(depth));
	snprintf(file, sizeof(file), "%s_%d_in.bin", far ? "far" : "in", f);
	writeFile(file, inputs, sizeof(inputs));
	scePowerTick(PSP_POWER_TICK_ALL);
}

int main(int argc, char *argv[]) {
	sceIoMkdir("host0:/zclamp", 0777);
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

	for (int f = 0; f < FRAMES; f++)
		frame(0, f);
	for (int f = 0; f < FRAMES; f++)
		frame(1, f);

	if (logFd >= 0) {
		sceIoWrite(logFd, "zclamp: done\n", 13);
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
