// Records which CLUT entry a texel reads with a CLUT per level (TEXMODE bit
// 8): 8 x 8 texel through-mode sprites, one per 8 x 8 pixel cell, each at a
// constant level (TEXLEVEL mode 1), the CLUT's 512 16-bit entries holding
// their own index (entry i = 0x8000 | i, format 5650), so a pixel's colour
// gives the entry. Every level is 8 x 8 texels in a buffer 32 texels wide,
// texel (x, y) of level L holding (x + 8 y + 37 L) & mask; textures CLUT4,
// CLUT8, CLUT16 and CLUT32, levels 0..7, CLUTFORMAT shifts, masks and
// offsets (configs below), with bit 8 set (frame 0) and clear (frame 1).
// Frame 2: where the rows of a buffer lie, CLUT4..CLUT32, 5650 and 8888 at
// level 0 with buffer widths 1..64 (cell level = the width), the buffer's
// byte k holding k & 255. The colour buffer goes to host0:/clut/frame_<n>.bin (272 rows of
// 512 8888 pixels), the cells' settings to host0:/clut/cells_<n>.bin (per
// cell format, level, CLUTFORMAT, TEXMODE as 32-bit words).

#include <pspkernel.h>
#include <pspge.h>
#include <pspgu.h>
#include <psppower.h>
#include <stdio.h>
#include <string.h>

PSP_MODULE_INFO("GECLUT", 0, 1, 0);
PSP_MAIN_THREAD_ATTR(PSP_THREAD_ATTR_USER | PSP_THREAD_ATTR_VFPU);
PSP_HEAP_SIZE_KB(1024);

#define W 480
#define H 272
#define COLS 60
#define ROWS 34
#define CELLS (COLS * ROWS)

typedef struct {
	unsigned short u, v;
	short x, y, z;
} Vert;

static unsigned int __attribute__((aligned(64))) setupList[4096];
static unsigned int __attribute__((aligned(64))) list[CELLS * 16 + 4096];
static Vert __attribute__((aligned(64))) verts[CELLS * 2];
static unsigned short __attribute__((aligned(64))) clut[512];
// Per format (4..7) and level: 32 x 8 texels of up to 32 bits.
#define BW 32
static unsigned char __attribute__((aligned(64))) tex[4][8][BW * 8 * 4];
static unsigned char __attribute__((aligned(64))) ramp[8192];
static unsigned int __attribute__((aligned(64))) colors[512 * H];
static unsigned int cells[CELLS * 4];

static unsigned int *cmd;

static void emit(unsigned int c, unsigned int arg) {
	*cmd++ = (c << 24) | (arg & 0xFFFFFF);
}

enum {
	VADDR = 0x01, PRIM = 0x04, BASE = 0x10, VTYPE = 0x12, LIGHTING = 0x17, CLIPENABLE = 0x1C, CULLENABLE = 0x1D,
	TEXENABLE = 0x1E, FOGENABLE = 0x1F, DITHERENABLE = 0x20, BLENDENABLE = 0x21, ALPHATEST = 0x22, ZTESTEN = 0x23,
	STENCILTEST = 0x24, ANTIALIAS = 0x25, COLORTEST = 0x27, LOGICOP = 0x28, SHADEMODE = 0x50,
	TEXADDR0 = 0xA0, TEXBUFWIDTH0 = 0xA8, CLUTADDR = 0xB0, CLUTADDRUPPER = 0xB1, TEXSIZE0 = 0xB8,
	TEXMODE = 0xC2, TEXFORMAT = 0xC3, CLUTLOAD = 0xC4, CLUTFORMAT = 0xC5, TEXFILTER = 0xC6, TEXWRAP = 0xC7,
	TEXLEVEL = 0xC8, TEXFUNC = 0xC9, TEXFLUSH = 0xCB,
	MINZ = 0xD6, MAXZ = 0xD7, MASKRGB = 0xE8, MASKALPHA = 0xE9,
};

static void writeFile(const char *name, const void *p, int bytes) {
	char path[96];
	snprintf(path, sizeof(path), "host0:/clut/%s", name);
	SceUID fd = sceIoOpen(path, PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	if (fd >= 0) {
		sceIoWrite(fd, p, bytes);
		sceIoClose(fd);
	}
}

// CLUTFORMAT configs (format 0 = 5650 in bits 0-1): shift (bits 2-6), mask
// (bits 8-15), offset (bits 16-20, in 16 entries).
static const unsigned int configs[] = {
	0x00FF00, 0x01FF00, 0x05FF00, 0x10FF00, 0x1FFF00, 0x000F00, 0x020F00, 0x003F00,
	0x00FF10, 0x00FF20, 0x0FFF00, 0x08FF00, 0x00FF04, 0x030700, 0x00FF3C, 0x11FF00,
};
#define NCONFIGS (sizeof(configs) / sizeof(configs[0]))

static void frame(int f) {
	// f: 0 multi-CLUT on, 1 off, 2 narrow buffers.
	int multi = f == 0;
	cmd = list;
	emit(CLIPENABLE, 0); emit(CULLENABLE, 0); emit(FOGENABLE, 0);
	emit(DITHERENABLE, 0); emit(BLENDENABLE, 0); emit(ALPHATEST, 0); emit(ZTESTEN, 0);
	emit(STENCILTEST, 0); emit(ANTIALIAS, 0); emit(COLORTEST, 0); emit(LOGICOP, 0); emit(LIGHTING, 0);
	emit(SHADEMODE, 0); emit(MASKRGB, 0); emit(MASKALPHA, 0); emit(MINZ, 0); emit(MAXZ, 0xFFFF);
	emit(TEXENABLE, 1);
	emit(TEXFUNC, 3 | (1 << 8));   // replace, RGBA
	emit(TEXFILTER, 4);            // nearest, mipmaps nearest; magnify nearest
	emit(TEXWRAP, 0);
	unsigned int ca = (unsigned int)clut;
	emit(CLUTADDR, ca & 0xFFFFFF);
	emit(CLUTADDRUPPER, (ca >> 8) & 0x0F0000);
	emit(VTYPE, (1 << 23) | (2 << 7) | 2);   // through, 16-bit positions and UVs
	int c = 0;
	for (int k = 0; f == 2 && k < 384; k++) {
		static const int fmts[6] = { 4, 5, 6, 7, 0, 3 };
		int fmt = fmts[k >> 6], bw = (k & 63) + 1;
		emit(CLUTFORMAT, 0x00FF00);
		emit(CLUTLOAD, 32);
		emit(TEXFORMAT, fmt);
		emit(TEXMODE, 0);
		unsigned int ta = (unsigned int)ramp;
		emit(TEXADDR0, ta & 0xFFFFFF);
		emit(TEXBUFWIDTH0, ((ta >> 8) & 0x0F0000) | bw);
		emit(TEXSIZE0, 3 | (3 << 8));
		emit(TEXFLUSH, 0);
		emit(TEXLEVEL, 1);
		int cx = (c % COLS) * 8, cy = (c / COLS) * 8;
		Vert *v = &verts[c * 2];
		v[0].u = 0; v[0].v = 0; v[0].x = cx; v[0].y = cy; v[0].z = 0;
		v[1].u = 8; v[1].v = 8; v[1].x = cx + 8; v[1].y = cy + 8; v[1].z = 0;
		cells[c * 4] = fmt; cells[c * 4 + 1] = bw; cells[c * 4 + 2] = 0x00FF00; cells[c * 4 + 3] = 0;
		unsigned int a = (unsigned int)v;
		emit(BASE, (a >> 8) & 0x0F0000);
		emit(VADDR, a & 0xFFFFFF);
		emit(PRIM, (6 << 16) | 2);
		c++;
	}
	for (int fmt = 0; f < 2 && fmt < 4; fmt++)
		for (int level = 0; level < 8; level++)
			for (unsigned int k = 0; k < NCONFIGS; k++) {
				if (c >= CELLS)
					break;
				emit(CLUTFORMAT, configs[k]);
				emit(CLUTLOAD, 32);
				emit(TEXFORMAT, 4 + fmt);
				emit(TEXMODE, (multi ? 0x100 : 0) | (7 << 16));
				for (int l = 0; l < 8; l++) {
					unsigned int ta = (unsigned int)tex[fmt][l];
					emit(TEXADDR0 + l, ta & 0xFFFFFF);
					emit(TEXBUFWIDTH0 + l, ((ta >> 8) & 0x0F0000) | BW);
					emit(TEXSIZE0 + l, 3 | (3 << 8));
				}
				emit(TEXFLUSH, 0);
				emit(TEXLEVEL, 1 | ((level * 16) << 16));
				int cx = (c % COLS) * 8, cy = (c / COLS) * 8;
				Vert *v = &verts[c * 2];
				v[0].u = 0; v[0].v = 0; v[0].x = cx; v[0].y = cy; v[0].z = 0;
				v[1].u = 8; v[1].v = 8; v[1].x = cx + 8; v[1].y = cy + 8; v[1].z = 0;
				cells[c * 4] = 4 + fmt; cells[c * 4 + 1] = level; cells[c * 4 + 2] = configs[k];
				cells[c * 4 + 3] = (multi ? 0x100 : 0) | (7 << 16);
				unsigned int a = (unsigned int)v;
				emit(BASE, (a >> 8) & 0x0F0000);
				emit(VADDR, a & 0xFFFFFF);
				emit(PRIM, (6 << 16) | 2);
				c++;
			}
	for (; c < CELLS; c++)
		cells[c * 4] = 0;
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
	snprintf(file, sizeof(file), "frame_%d.bin", f);
	writeFile(file, colors, sizeof(colors));
	snprintf(file, sizeof(file), "cells_%d.bin", f);
	writeFile(file, cells, sizeof(cells));
	scePowerTick(PSP_POWER_TICK_ALL);
}

int main(int argc, char *argv[]) {
	sceIoMkdir("host0:/clut", 0777);
	SceUID logFd = sceIoOpen("host0:/__testoutput.txt", PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);

	for (int i = 0; i < 512; i++)
		clut[i] = 0x8000 | i;
	for (int l = 0; l < 8; l++)
		for (int i = 0; i < 64; i++) {
			int x = i & 7, y = i >> 3;
			unsigned int v = x + 8 * y + 37 * l;
			int k = y * BW + x;
			// CLUT4: two texels a byte, the first in the low nibble.
			if (x & 1)
				tex[0][l][k >> 1] |= (v & 15) << 4;
			else
				tex[0][l][k >> 1] = v & 15;
			tex[1][l][k] = v & 255;
			((unsigned short *)tex[2][l])[k] = v & 0xFFFF;
			((unsigned int *)tex[3][l])[k] = v;
		}
	for (int k = 0; k < (int)sizeof(ramp); k++)
		ramp[k] = k & 255;
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

	frame(0);
	frame(1);
	frame(2);

	if (logFd >= 0) {
		sceIoWrite(logFd, "clut: 3 frames\n", 15);
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
