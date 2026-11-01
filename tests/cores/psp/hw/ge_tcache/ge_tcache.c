// Records what a sprite reads when it textures from the buffer it draws
// into: a 4444 render target 64 pixels wide (64 x 64 at VRAM 0x154000, as
// gpu/exact's texture cache jobs), every pixel holding its own index
// (y * 64 + x), then one or more through-mode sprites with a 64 x 64 4444
// texture at the same address (nearest, replace) shifted against their
// pixels; the target is read back after each case
// (host0:/tcache/case_<n>.bin, 64 x 64 16-bit values), the cases listed in
// cases.bin (per case: count, then per sprite x0, y0, x1, y1, u0, v0, flush
// before it).

#include <pspkernel.h>
#include <pspge.h>
#include <pspgu.h>
#include <psppower.h>
#include <stdio.h>
#include <string.h>

PSP_MODULE_INFO("GETCACHE", 0, 1, 0);
PSP_MAIN_THREAD_ATTR(PSP_THREAD_ATTR_USER | PSP_THREAD_ATTR_VFPU);
PSP_HEAP_SIZE_KB(1024);

#define FB 0x154000
#define MAXS 4

typedef struct {
	unsigned short u, v;
	short x, y, z;
} Vert;

typedef struct {
	int n;
	int s[MAXS][7];
} Case;

static unsigned int __attribute__((aligned(64))) setupList[1024];
static unsigned int __attribute__((aligned(64))) list[4096];
static Vert __attribute__((aligned(64))) verts[MAXS * 2];
static unsigned short buf[64 * 64];
static Case cases[256];
static int ncases;

static unsigned int *cmd;
static SceUID logFd = -1;

static void logLine(const char *s) {
	if (logFd >= 0)
		sceIoWrite(logFd, s, strlen(s));
}

static void emit(unsigned int c, unsigned int arg) {
	*cmd++ = (c << 24) | (arg & 0xFFFFFF);
}

enum {
	VADDR = 0x01, PRIM = 0x04, BASE = 0x10, VTYPE = 0x12, LIGHTING = 0x17, CLIPENABLE = 0x1C, CULLENABLE = 0x1D,
	TEXENABLE = 0x1E, FOGENABLE = 0x1F, DITHERENABLE = 0x20, BLENDENABLE = 0x21, ALPHATEST = 0x22, ZTESTEN = 0x23,
	STENCILTEST = 0x24, ANTIALIAS = 0x25, COLORTEST = 0x27, LOGICOP = 0x28, SHADEMODE = 0x50,
	FRAMEBUFPTR = 0x9C, FRAMEBUFWIDTH = 0x9D, TEXADDR0 = 0xA0, TEXBUFWIDTH0 = 0xA8, TEXSIZE0 = 0xB8,
	TEXMODE = 0xC2, TEXFORMAT = 0xC3, TEXFILTER = 0xC6, TEXWRAP = 0xC7, TEXLEVEL = 0xC8, TEXFUNC = 0xC9,
	TEXFLUSH = 0xCB, TEXSYNC = 0xCC, FRAMEBUFPIXFORMAT = 0xD2,
	REGION1 = 0x15, REGION2 = 0x16, SCISSOR1 = 0xD4, SCISSOR2 = 0xD5,
	MINZ = 0xD6, MAXZ = 0xD7, MASKRGB = 0xE8, MASKALPHA = 0xE9,
};

static void addCase(int n, const int s[][7]) {
	Case *c = &cases[ncases++];
	c->n = n;
	memcpy(c->s, s, sizeof(int) * 7 * n);
}

static void runCase(int k) {
	Case *c = &cases[k];
	volatile unsigned short *fb = (volatile unsigned short *)(0x44000000 + FB);
	for (int i = 0; i < 64 * 64; i++)
		fb[i] = (unsigned short)i;
	sceKernelDcacheWritebackInvalidateAll();

	cmd = list;
	emit(CLIPENABLE, 0); emit(CULLENABLE, 0); emit(FOGENABLE, 0);
	emit(DITHERENABLE, 0); emit(BLENDENABLE, 0); emit(ALPHATEST, 0); emit(ZTESTEN, 0);
	emit(STENCILTEST, 0); emit(ANTIALIAS, 0); emit(COLORTEST, 0); emit(LOGICOP, 0); emit(LIGHTING, 0);
	emit(SHADEMODE, 0); emit(MASKRGB, 0); emit(MASKALPHA, 0); emit(MINZ, 0); emit(MAXZ, 0xFFFF);
	emit(FRAMEBUFPTR, FB & 0xFFFFFF); emit(FRAMEBUFWIDTH, ((FB >> 8) & 0xFF0000) | 64);
	emit(FRAMEBUFPIXFORMAT, 2);
	emit(REGION1, 0); emit(REGION2, 63 | (63 << 10));
	emit(SCISSOR1, 0); emit(SCISSOR2, 63 | (63 << 10));
	emit(TEXENABLE, 1);
	emit(TEXFUNC, 3 | (1 << 8));
	emit(TEXFILTER, 0);
	emit(TEXWRAP, 0);
	emit(TEXMODE, 0);
	emit(TEXFORMAT, 2);
	emit(TEXLEVEL, 1);
	emit(TEXADDR0, (0x04000000 | FB) & 0xFFFFFF);
	emit(TEXBUFWIDTH0, (((0x04000000 | FB) >> 8) & 0x0F0000) | 64);
	emit(TEXSIZE0, 6 | (6 << 8));
	emit(TEXFLUSH, 0);
	emit(VTYPE, (1 << 23) | (2 << 7) | 2);
	for (int i = 0; i < c->n; i++) {
		int *s = c->s[i];
		Vert *v = &verts[i * 2];
		v[0].u = s[4]; v[0].v = s[5]; v[0].x = s[0]; v[0].y = s[1]; v[0].z = 0;
		v[1].u = s[4] + (s[2] - s[0]); v[1].v = s[5] + (s[3] - s[1]); v[1].x = s[2]; v[1].y = s[3]; v[1].z = 0;
		if (s[6] & 1)
			emit(TEXFLUSH, 0);
		if (s[6] & 2)
			emit(TEXSYNC, 0);
		unsigned int a = (unsigned int)v;
		emit(BASE, (a >> 8) & 0x0F0000);
		emit(VADDR, a & 0xFFFFFF);
		emit(PRIM, (6 << 16) | 2);
	}
	emit(0x0F, 0);
	emit(0x0C, 0);
	sceKernelDcacheWritebackAll();
	int id = sceGeListEnQueue(list, cmd, -1, NULL);
	sceGeListSync(id, 0);
	for (int i = 0; i < 64 * 64; i++)
		buf[i] = fb[i];
	char path[96];
	snprintf(path, sizeof(path), "host0:/tcache/case_%d.bin", k);
	SceUID fd = sceIoOpen(path, PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	if (fd >= 0) {
		sceIoWrite(fd, buf, sizeof(buf));
		sceIoClose(fd);
	}
	scePowerTick(PSP_POWER_TICK_ALL);
}

int main(int argc, char *argv[]) {
	sceIoMkdir("host0:/tcache", 0777);
	logFd = sceIoOpen("host0:/__testoutput.txt", PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	logLine("tcache: start\n");

	sceGuInit();
	sceGuStart(GU_DIRECT, setupList);
	sceGuDrawBuffer(GU_PSM_8888, (void *)0, 512);
	sceGuDispBuffer(480, 272, (void *)0, 512);
	sceGuDepthBuffer((void *)0x88000, 512);
	sceGuOffset(2048 - 240, 2048 - 136);
	sceGuViewport(2048, 2048, 480, 272);
	sceGuScissor(0, 0, 480, 272);
	sceGuEnable(GU_SCISSOR_TEST);
	sceGuFinish();
	sceGuSync(0, 0);
	sceGuDisplay(1);
	logLine("tcache: gu ready\n");

	// One sprite: dst (x0, y0)-(x1, y1) from texel (u0, v0); shifts in x and
	// y, sizes 8 to 64.
	static const int shifts[][2] = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 2, 0 }, { 4, 0 }, { 8, 0 }, { 16, 0 },
		{ 32, 0 }, { -8, 0 }, { -16, 0 }, { 0, 2 }, { 0, 4 }, { 0, 8 }, { 0, 16 }, { 0, -8 }, { 1, 1 }, { -1, -1 } };
	static const int sizes[][2] = { { 16, 16 }, { 32, 32 }, { 48, 16 }, { 16, 48 } };
	for (unsigned int i = 0; i < sizeof(shifts) / sizeof(shifts[0]); i++)
		for (unsigned int j = 0; j < sizeof(sizes) / sizeof(sizes[0]); j++) {
			int dx = shifts[i][0], dy = shifts[i][1], w = sizes[j][0], h = sizes[j][1];
			int x0 = 16, y0 = 8;
			int s[1][7] = { { x0 + dx, y0 + dy, x0 + dx + w, y0 + dy + h, x0, y0, 1 } };
			addCase(1, s);
		}
	// gpu/exact's sequence (16 x 16 at 0, 0: +1 x, +1 y, -1 y), without and
	// with a flush, and with sync, between the sprites.
	for (int fl = 0; fl < 4; fl++) {
		int f = fl == 0 ? 0 : (fl == 1 ? 1 : (fl == 2 ? 2 : 3));
		int s[3][7] = { { 1, 0, 17, 16, 0, 0, 1 }, { 0, 1, 16, 17, 0, 0, f }, { 0, -1, 16, 15, 0, 0, f } };
		addCase(3, s);
	}
	// Two sprites, the second reading what the first wrote.
	for (int fl = 0; fl < 4; fl++) {
		int s[2][7] = { { 0, 0, 32, 32, 32, 32, 1 }, { 32, 32, 64, 64, 0, 0, fl } };
		addCase(2, s);
	}
	for (int k = 0; k < ncases; k++) {
		char line[32];
		snprintf(line, sizeof(line), "case %d\n", k);
		logLine(line);
		runCase(k);
	}
	SceUID fd = sceIoOpen("host0:/tcache/cases.bin", PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	if (fd >= 0) {
		sceIoWrite(fd, cases, sizeof(Case) * ncases);
		sceIoClose(fd);
	}

	logLine("tcache: done\n");
	if (logFd >= 0)
		sceIoClose(logFd);
	sceGuTerm();
	SceUID fin = sceIoOpen("host0:/__testfinish.txt", PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	if (fin >= 0) {
		sceIoWrite(fin, "1", 1);
		sceIoClose(fin);
	}
	sceKernelExitGame();
	return 0;
}
