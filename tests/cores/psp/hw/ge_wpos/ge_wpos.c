// Records how the lighting unit takes a vertex's world position: a random
// world matrix with large entries (each in [-256, 256], as gpu/exact's light
// vector jobs) and its inverse as the view matrix, so a point at (x, y, 0)
// still lands on its pixel; one point every second pixel each way
// (x = ((px - 240) * 2 + 1) / 512, y = ((136 - py) * 2 - 1) / 512) with a
// spot light at its world position plus a random offset (length 1 to 64),
// pointing back along the offset give or take 0.1, cutoff -1. The ambient
// light is green, so every lit point shows green 255 and red the spot
// factor (the light's ambient is red). Exponent 10 on even frames, 40 on odd.
// Frames go to host0:/wpos/f<n>.bin (272 rows of 512 words), the inputs to
// f<n>_in.bin: the world matrix (12 floats as 24-bit bits), then per point
// the light x, y, z and direction x, y, z (24-bit float bits).

#include <pspkernel.h>
#include <pspdisplay.h>
#include <pspge.h>
#include <pspgu.h>
#include <psppower.h>
#include <stdio.h>
#include <string.h>

PSP_MODULE_INFO("GEWPOS", 0, 1, 0);
PSP_MAIN_THREAD_ATTR(PSP_THREAD_ATTR_USER | PSP_THREAD_ATTR_VFPU);
PSP_HEAP_SIZE_KB(1024);

#define W 480
#define H 272
#define PW (W / 2)
#define PH (H / 2)
#define SAMPLES (PW * PH)
#define FRAMES 8

static unsigned int __attribute__((aligned(64))) setupList[4096];
static unsigned int __attribute__((aligned(64))) list[SAMPLES * 10 + 4096];
static float __attribute__((aligned(64))) verts[SAMPLES * 6];
static unsigned int __attribute__((aligned(64))) frame[512 * H];
static unsigned int inputs[12 + SAMPLES * 6];

static unsigned int *cmd;
static unsigned int rng = 0x0BADC0DE;

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

static float vsqrt(float x) {
	if (x <= 0.0f)
		return 0.0f;
	float r = x > 1.0f ? x : 1.0f;
	for (int k = 0; k < 40; k++)
		r = 0.5f * (r + x / r);
	return r;
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

static void writeFile(const char *name, const void *p, int bytes) {
	char path[96];
	snprintf(path, sizeof(path), "host0:/wpos/%s", name);
	SceUID fd = sceIoOpen(path, PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	if (fd >= 0) {
		sceIoWrite(fd, p, bytes);
		sceIoClose(fd);
	}
}

static void run(int f) {
	// World: rows of the 3x3 part (column-major registers: m[col * 3 + row])
	// and the translation, all 24-bit floats.
	float m[12];
	for (int i = 0; i < 12; i++) {
		inputs[i] = f24(frand(-256.0f, 256.0f));
		m[i] = fromF24(inputs[i]);
	}
	// a[r][c] = m[c * 3 + r]; the inverse of the 3x3 part and of the whole.
	float a00 = m[0], a10 = m[1], a20 = m[2], a01 = m[3], a11 = m[4], a21 = m[5], a02 = m[6], a12 = m[7], a22 = m[8];
	float det = a00 * (a11 * a22 - a12 * a21) - a01 * (a10 * a22 - a12 * a20) + a02 * (a10 * a21 - a11 * a20);
	float id = 1.0f / det;
	float i00 = (a11 * a22 - a12 * a21) * id, i01 = (a02 * a21 - a01 * a22) * id, i02 = (a01 * a12 - a02 * a11) * id;
	float i10 = (a12 * a20 - a10 * a22) * id, i11 = (a00 * a22 - a02 * a20) * id, i12 = (a02 * a10 - a00 * a12) * id;
	float i20 = (a10 * a21 - a11 * a20) * id, i21 = (a01 * a20 - a00 * a21) * id, i22 = (a00 * a11 - a01 * a10) * id;
	float tx = m[9], ty = m[10], tz = m[11];
	float v[12] = { i00, i10, i20, i01, i11, i21, i02, i12, i22,
		-(i00 * tx + i01 * ty + i02 * tz), -(i10 * tx + i11 * ty + i12 * tz), -(i20 * tx + i21 * ty + i22 * tz) };

	cmd = list;
	emit(CLIPENABLE, 0); emit(CULLENABLE, 0); emit(TEXENABLE, 0); emit(FOGENABLE, 0);
	emit(DITHERENABLE, 0); emit(BLENDENABLE, 0); emit(ALPHATEST, 0); emit(ZTEST, 0);
	emit(STENCILTEST, 0); emit(COLORTEST, 0); emit(LOGICOP, 0); emit(ZWRITEDISABLE, 1);
	emit(MASKRGB, 0); emit(MASKALPHA, 0); emit(SHADEMODE, 0); emit(REVERSENORMAL, 0);
	emit(WORLDNUM, 0);
	for (int i = 0; i < 12; i++) emit(WORLDDATA, inputs[i]);
	emit(VIEWNUM, 0);
	for (int i = 0; i < 12; i++) emit(VIEWDATA, f24(v[i]));
	emit(PROJNUM, 0);
	for (int i = 0; i < 16; i++) emit(PROJDATA, i / 4 == i % 4 ? f24(1.0f) : 0);
	emit(VPXS, f24(256.0f)); emit(VPYS, f24(-256.0f)); emit(VPZS, f24(0.0f));
	emit(VPXC, f24(2048.0f)); emit(VPYC, f24(2048.0f)); emit(VPZC, f24(0.0f));
	emit(OFFSETX, (2048 - 240) << 4); emit(OFFSETY, (2048 - 136) << 4);
	emit(MINZ, 0); emit(MAXZ, 0xFFFF);
	emit(VTYPE, (3 << 5) | (3 << 7));
	emit(LIGHTING, 1);
	emit(LIGHTENABLE0, 1);
	emit(LIGHTENABLE0 + 1, 0); emit(LIGHTENABLE0 + 2, 0); emit(LIGHTENABLE0 + 3, 0);
	emit(MATUPDATE, 0); emit(MATEMISSIVE, 0); emit(AMBIENTCOLOR, 0xFF00); emit(AMBIENTALPHA, 0xFF);
	emit(MATAMBIENT, 0xFFFFFF); emit(MATALPHA, 0xFF); emit(MATDIFFUSE, 0); emit(MATSPECULAR, 0);
	emit(LIGHTMODE, 0);
	emit(LIGHTTYPE0, 2 << 8);
	emit(LAC0, 0xFF); emit(LAC0 + 1, 0); emit(LAC0 + 2, 0);
	emit(LKA0, f24(1.0f)); emit(LKA0 + 1, 0); emit(LKA0 + 2, 0);
	emit(LKS0, f24((f & 1) ? 40.0f : 10.0f));
	emit(LKO0, f24(-1.0f));
	for (int s = 0; s < SAMPLES; s++) {
		int px = (s % PW) * 2, py = (s / PW) * 2;
		float x = worldX(px), y = worldY(py);
		float wx = m[0] * x + m[3] * y + m[9];
		float wy = m[1] * x + m[4] * y + m[10];
		float wz = m[2] * x + m[5] * y + m[11];
		float ox, oy, oz, len;
		do {
			ox = frand(-1.0f, 1.0f); oy = frand(-1.0f, 1.0f); oz = frand(-1.0f, 1.0f);
			len = vsqrt(ox * ox + oy * oy + oz * oz);
		} while (len < 0.1f || len > 1.0f);
		float k = frand(1.0f, 64.0f) / len;
		unsigned int *in = &inputs[12 + s * 6];
		in[0] = f24(wx + ox * k); in[1] = f24(wy + oy * k); in[2] = f24(wz + oz * k);
		float dl = frand(0.5f, 2.0f) / len;
		in[3] = f24(ox * dl + frand(-0.1f, 0.1f));
		in[4] = f24(oy * dl + frand(-0.1f, 0.1f));
		in[5] = f24(oz * dl + frand(-0.1f, 0.1f));
		for (int c = 0; c < 3; c++) emit(LX0 + c, in[c]);
		for (int c = 0; c < 3; c++) emit(LDX0 + c, in[3 + c]);
		float *vv = &verts[s * 6];
		vv[0] = 0.0f; vv[1] = 0.0f; vv[2] = 1.0f;
		vv[3] = x; vv[4] = y; vv[5] = 0.0f;
		unsigned int a = (unsigned int)vv;
		emit(BASE, (a >> 8) & 0x0F0000);
		emit(VADDR, a & 0xFFFFFF);
		emit(PRIM, (0 << 16) | 1);
	}
	emit(0x0F, 0);
	emit(0x0C, 0);
	sceKernelDcacheWritebackAll();

	sceGuStart(GU_DIRECT, setupList);
	sceGuClearColor(0);
	sceGuClear(GU_COLOR_BUFFER_BIT);
	sceGuFinish();
	sceGuSync(0, 0);
	int id2 = sceGeListEnQueue(list, cmd, -1, NULL);
	sceGeListSync(id2, 0);

	const volatile unsigned int *vram = (const volatile unsigned int *)0x44000000;
	for (int i = 0; i < 512 * H; i++)
		frame[i] = vram[i];
	char file[64];
	snprintf(file, sizeof(file), "f%d.bin", f);
	writeFile(file, frame, sizeof(frame));
	snprintf(file, sizeof(file), "f%d_in.bin", f);
	writeFile(file, inputs, sizeof(inputs));
	scePowerTick(PSP_POWER_TICK_ALL);
}

int main(int argc, char *argv[]) {
	sceIoMkdir("host0:/wpos", 0777);
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
		run(f);

	if (logFd >= 0) {
		sceIoWrite(logFd, "wpos: done\n", 11);
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
