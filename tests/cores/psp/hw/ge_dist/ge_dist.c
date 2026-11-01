// Records the distance the lighting unit takes for linear attenuation: one
// lit point per pixel (as ge_light: world x = ((px - 240) * 2 + 1) / 512,
// y = ((136 - py) * 2 - 1) / 512, z = 0, normal +z) and a point light, KA
// and KC 0, ambient white, so the colour is floor(256 / (KB d)). Every row
// has its own light offset from its points: even rows straight above at a
// random height, odd rows (mx / 512, my / 512, z) with random integers mx,
// my in [-1024, 1024] and a random z (exact differences, so one distance a
// row). Along a row KB runs over 480 consecutive 24-bit floats from about
// v / d, v random in [1, 2), so the colour steps where KB d crosses a
// threshold: the distance shows to its last bit.
// Frames go to host0:/dist/f<n>.bin (272 rows of 512 words), the inputs to
// f<n>_in.bin: per row the light offset x, y, z and the first KB, as 24-bit
// float bits in 32-bit words. Set "s" (s<n>.bin): the light straight above
// at every 24-bit float height of [1, 2), one a row, in order.

#include <pspkernel.h>
#include <pspdisplay.h>
#include <pspge.h>
#include <pspgu.h>
#include <psppower.h>
#include <stdio.h>
#include <string.h>

PSP_MODULE_INFO("GEDIST", 0, 1, 0);
PSP_MAIN_THREAD_ATTR(PSP_THREAD_ATTR_USER | PSP_THREAD_ATTR_VFPU);
PSP_HEAP_SIZE_KB(1024);

#define W 480
#define H 272
#define SAMPLES (W * H)
#define FRAMES 8
#define SWEEP_FRAMES 121

static unsigned int __attribute__((aligned(64))) setupList[4096];
static unsigned int __attribute__((aligned(64))) list[SAMPLES * 8 + 4096];
static float __attribute__((aligned(64))) verts[SAMPLES * 6];
static unsigned int __attribute__((aligned(64))) frame[512 * H];
static unsigned int inputs[H * 4];

static unsigned int *cmd;
static unsigned int rng = 0x2468ACE1;

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

static float fromF24(unsigned int b) {
	union { float f; unsigned int u; } v;
	v.u = b << 8;
	return v.f;
}

static float worldX(int px) { return (float)((px - 240) * 2 + 1) / 512.0f; }
static float worldY(int py) { return (float)((136 - py) * 2 - 1) / 512.0f; }

enum {
	VADDR = 0x01, PRIM = 0x04, BASE = 0x10, VTYPE = 0x12,
	LIGHTING = 0x17, LIGHTENABLE0 = 0x18, CLIPENABLE = 0x1C, CULLENABLE = 0x1D, TEXENABLE = 0x1E,
	FOGENABLE = 0x1F, DITHERENABLE = 0x20, BLENDENABLE = 0x21, ALPHATEST = 0x22, ZTEST = 0x23,
	STENCILTEST = 0x24, COLORTEST = 0x27, LOGICOP = 0x28,
	WORLDNUM = 0x3A, WORLDDATA = 0x3B, VIEWNUM = 0x3C, VIEWDATA = 0x3D, PROJNUM = 0x3E, PROJDATA = 0x3F,
	VPXS = 0x42, VPYS = 0x43, VPZS = 0x44, VPXC = 0x45, VPYC = 0x46, VPZC = 0x47,
	OFFSETX = 0x4C, OFFSETY = 0x4D, SHADEMODE = 0x50, REVERSENORMAL = 0x51,
	MATUPDATE = 0x53, MATEMISSIVE = 0x54, MATAMBIENT = 0x55, MATDIFFUSE = 0x56, MATSPECULAR = 0x57,
	MATALPHA = 0x58, MATSPECCOEF = 0x5B, AMBIENTCOLOR = 0x5C, AMBIENTALPHA = 0x5D, LIGHTMODE = 0x5E,
	LIGHTTYPE0 = 0x5F, LX0 = 0x63, LDX0 = 0x6F, LKA0 = 0x7B, LKS0 = 0x87, LKO0 = 0x8B, LAC0 = 0x8F,
	MINZ = 0xD6, MAXZ = 0xD7, ZWRITEDISABLE = 0xE7, MASKRGB = 0xE8, MASKALPHA = 0xE9,
};

static void identity(int num, int data, int n) {
	int cols = n == 16 ? 4 : 3;
	emit(num, 0);
	for (int i = 0; i < n; i++)
		emit(data, i / cols == i % cols ? f24(1.0f) : 0);
}

static void writeFile(const char *name, const void *p, int bytes) {
	char path[96];
	snprintf(path, sizeof(path), "host0:/dist/%s", name);
	SceUID fd = sceIoOpen(path, PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	if (fd >= 0) {
		sceIoWrite(fd, p, bytes);
		sceIoClose(fd);
	}
}

static void run(int f, int sweep) {
	cmd = list;
	emit(CLIPENABLE, 0); emit(CULLENABLE, 0); emit(TEXENABLE, 0); emit(FOGENABLE, 0);
	emit(DITHERENABLE, 0); emit(BLENDENABLE, 0); emit(ALPHATEST, 0); emit(ZTEST, 0);
	emit(STENCILTEST, 0); emit(COLORTEST, 0); emit(LOGICOP, 0); emit(ZWRITEDISABLE, 1);
	emit(MASKRGB, 0); emit(MASKALPHA, 0); emit(SHADEMODE, 0); emit(REVERSENORMAL, 0);
	identity(WORLDNUM, WORLDDATA, 12);
	identity(VIEWNUM, VIEWDATA, 12);
	identity(PROJNUM, PROJDATA, 16);
	emit(VPXS, f24(256.0f)); emit(VPYS, f24(-256.0f)); emit(VPZS, f24(0.0f));
	emit(VPXC, f24(2048.0f)); emit(VPYC, f24(2048.0f)); emit(VPZC, f24(0.0f));
	emit(OFFSETX, (2048 - 240) << 4); emit(OFFSETY, (2048 - 136) << 4);
	emit(MINZ, 0); emit(MAXZ, 0xFFFF);
	emit(VTYPE, (3 << 5) | (3 << 7));
	emit(LIGHTING, 1);
	emit(LIGHTENABLE0, 1);
	emit(LIGHTENABLE0 + 1, 0); emit(LIGHTENABLE0 + 2, 0); emit(LIGHTENABLE0 + 3, 0);
	emit(MATUPDATE, 0); emit(MATEMISSIVE, 0); emit(AMBIENTCOLOR, 0); emit(AMBIENTALPHA, 0xFF);
	emit(MATAMBIENT, 0xFFFFFF); emit(MATALPHA, 0xFF); emit(MATDIFFUSE, 0); emit(MATSPECULAR, 0);
	emit(LIGHTMODE, 0);
	emit(LIGHTTYPE0, 1 << 8);
	emit(LAC0, 0xFFFFFF); emit(LAC0 + 1, 0); emit(LAC0 + 2, 0);
	emit(LKA0, 0); emit(LKA0 + 2, 0);
	for (int py = 0; py < H; py++) {
		unsigned int *in = &inputs[py * 4];
		float ox = 0.0f, oy = 0.0f, oz;
		if (sweep)
			oz = fromF24(0x3F8000 + ((f * H + py) & 0x7FFF));
		else if (py & 1) {
			ox = (float)((int)(next() % 2049) - 1024) / 512.0f;
			oy = (float)((int)(next() % 2049) - 1024) / 512.0f;
			oz = frand(0.05f, 4.0f);
		} else
			oz = frand(0.25f, 16.0f);
		in[0] = f24(ox); in[1] = f24(oy); in[2] = f24(oz);
		float dx = fromF24(in[0]), dy = fromF24(in[1]), dz = fromF24(in[2]);
		float d2 = dx * dx + dy * dy + dz * dz;
		// sqrt by Newton steps (no libm): close enough for a starting KB.
		float d = d2 > 1.0f ? d2 : 1.0f;
		for (int k = 0; k < 30; k++)
			d = 0.5f * (d + d2 / d);
		float v = frand(1.0f, 2.0f);
		in[3] = f24(v / d) - 240;
		for (int px = 0; px < W; px++) {
			int s = py * W + px;
			float *vv = &verts[s * 6];
			vv[0] = 0.0f; vv[1] = 0.0f; vv[2] = 1.0f;
			vv[3] = worldX(px); vv[4] = worldY(py); vv[5] = 0.0f;
			emit(LX0, f24(worldX(px) + dx));
			emit(LX0 + 1, f24(worldY(py) + dy));
			emit(LX0 + 2, in[2]);
			emit(LKA0 + 1, in[3] + px);
			unsigned int a = (unsigned int)vv;
			emit(BASE, (a >> 8) & 0x0F0000);
			emit(VADDR, a & 0xFFFFFF);
			emit(PRIM, (0 << 16) | 1);
		}
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

	const volatile unsigned int *vram = (const volatile unsigned int *)0x44000000;
	for (int i = 0; i < 512 * H; i++)
		frame[i] = vram[i];
	char file[64];
	snprintf(file, sizeof(file), "%s%d.bin", sweep ? "s" : "f", f);
	writeFile(file, frame, sizeof(frame));
	snprintf(file, sizeof(file), "%s%d_in.bin", sweep ? "s" : "f", f);
	writeFile(file, inputs, sizeof(inputs));
	scePowerTick(PSP_POWER_TICK_ALL);
}

int main(int argc, char *argv[]) {
	sceIoMkdir("host0:/dist", 0777);
	SceUID logFd = sceIoOpen("host0:/__testoutput.txt", PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);

	sceGuInit();
	sceGuStart(GU_DIRECT, setupList);
	sceGuDrawBuffer(GU_PSM_8888, (void *)0, 512);
	sceGuDispBuffer(W, H, (void *)0, 512);
	sceGuDepthBuffer((void *)(512 * H * 4), 512);
	sceGuOffset(2048 - 240, 2048 - 136);
	sceGuViewport(2048, 2048, W, H);
	sceGuScissor(0, 0, W, H);
	sceGuEnable(GU_SCISSOR_TEST);
	sceGuFinish();
	sceGuSync(0, 0);
	sceGuDisplay(1);

	for (int f = 0; f < FRAMES; f++)
		run(f, 0);
	for (int f = 0; f < SWEEP_FRAMES; f++)
		run(f, 1);

	if (logFd >= 0) {
		sceIoWrite(logFd, "dist: done\n", 11);
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
