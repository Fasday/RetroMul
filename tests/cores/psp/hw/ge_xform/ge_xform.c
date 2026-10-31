// Records the GE's vertex arithmetic through the depth it writes: one point
// per pixel, each with its own z and transform registers, depth test always
// passing and depth writes on; the depth buffer is read back through VRAM's
// mirrors (host0:/xform/<name>_<view>.bin, 272 rows of 512 16-bit values;
// view 0 plain, 2 at +0x200000, 6 at +0x600000).
//
// Point s is at pixel (s % 480, s / 480): x = ((px - 240) + 0.5) / 240 and
// y = ((136 - py) - 0.5) / 136 as floats, so with identity matrices and the
// usual viewport (scale 240, -136, centre 2048, offset 2048 - 240/136) it
// lands on its pixel. The z values and the registers each experiment varies
// come from a fixed xorshift sequence; host0:/xform/<name>_in.bin gets, per
// sample, the input z and the varied words.

#include <pspkernel.h>
#include <pspge.h>
#include <pspgu.h>
#include <psppower.h>
#include <stdio.h>
#include <string.h>

PSP_MODULE_INFO("GEXFORM", 0, 1, 0);
PSP_MAIN_THREAD_ATTR(PSP_THREAD_ATTR_USER | PSP_THREAD_ATTR_VFPU);
PSP_HEAP_SIZE_KB(1024);

#define W 480
#define H 272
#define N 65536
#define ZBUF 0x88000

static unsigned int __attribute__((aligned(64))) setupList[4096];
static unsigned int __attribute__((aligned(64))) list[N * 24 + 4096];
static float __attribute__((aligned(64))) verts[N * 3];
static unsigned short __attribute__((aligned(64))) depth[512 * H];
static unsigned int inputs[N * 4];

static unsigned int *cmd;
static unsigned int rng = 0x9E3779B9;

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

static unsigned int f24(float f) {
	return bits(f) >> 8;
}

// A random float in [lo, hi) with all 24 significand bits random.
static float frand(float lo, float hi) {
	return lo + (hi - lo) * ((next() >> 8) / 16777216.0f);
}

enum {
	VADDR = 0x01, PRIM = 0x04, BASE = 0x10, VTYPE = 0x12, LIGHTING = 0x17, CLIPENABLE = 0x1C, CULLENABLE = 0x1D,
	TEXENABLE = 0x1E, FOGENABLE = 0x1F, DITHERENABLE = 0x20, BLENDENABLE = 0x21, ALPHATEST = 0x22, ZTESTEN = 0x23,
	STENCILTEST = 0x24, COLORTEST = 0x27, LOGICOP = 0x28,
	WORLDNUM = 0x3A, WORLDDATA = 0x3B, VIEWNUM = 0x3C, VIEWDATA = 0x3D, PROJNUM = 0x3E, PROJDATA = 0x3F,
	VPXS = 0x42, VPYS = 0x43, VPZS = 0x44, VPXC = 0x45, VPYC = 0x46, VPZC = 0x47, OFFSETX = 0x4C, OFFSETY = 0x4D,
	SHADEMODE = 0x50, MATAMBIENT = 0x55, MATALPHA = 0x58, ZBUFPTR = 0x9E, ZBUFWIDTH = 0x9F,
	MINZ = 0xD6, MAXZ = 0xD7, ZTEST = 0xDE, ZWRITEDISABLE = 0xE7, MASKRGB = 0xE8, MASKALPHA = 0xE9,
};

static void matrix(int num, int data, int n, const float *m) {
	emit(num, 0);
	for (int i = 0; i < n; i++)
		emit(data, f24(m[i]));
}

static const float ident12[12] = { 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0 };
static const float ident16[16] = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

static void baseState(void) {
	emit(CLIPENABLE, 0); emit(CULLENABLE, 0); emit(TEXENABLE, 0); emit(FOGENABLE, 0);
	emit(DITHERENABLE, 0); emit(BLENDENABLE, 0); emit(ALPHATEST, 0); emit(STENCILTEST, 0);
	emit(COLORTEST, 0); emit(LOGICOP, 0); emit(LIGHTING, 0); emit(SHADEMODE, 0);
	emit(MASKRGB, 0); emit(MASKALPHA, 0);
	emit(ZTESTEN, 1); emit(ZTEST, 1); emit(ZWRITEDISABLE, 0);
	emit(ZBUFPTR, ZBUF & 0xFFFFFF); emit(ZBUFWIDTH, 512);
	emit(MINZ, 0); emit(MAXZ, 0xFFFF);
	emit(MATAMBIENT, 0xFFFFFF); emit(MATALPHA, 0xFF);
	matrix(WORLDNUM, WORLDDATA, 12, ident12);
	matrix(VIEWNUM, VIEWDATA, 12, ident12);
	matrix(PROJNUM, PROJDATA, 16, ident16);
	emit(VPXS, f24(240.0f)); emit(VPYS, f24(-136.0f));
	emit(VPXC, f24(2048.0f)); emit(VPYC, f24(2048.0f));
	emit(VPZS, f24(32768.0f)); emit(VPZC, f24(32768.0f));
	emit(OFFSETX, (2048 - 240) << 4); emit(OFFSETY, (2048 - 136) << 4);
	emit(VTYPE, 3 << 7);
}

static void point(int s, float z) {
	int px = s % W, py = s / W;
	float *v = &verts[s * 3];
	v[0] = ((float)(px - 240) + 0.5f) / 240.0f;
	v[1] = ((float)(136 - py) - 0.5f) / 136.0f;
	v[2] = z;
	unsigned int a = (unsigned int)v;
	emit(BASE, (a >> 8) & 0x0F0000);
	emit(VADDR, a & 0xFFFFFF);
	emit(PRIM, (0 << 16) | 1);
	inputs[s * 4] = bits(z);
}

typedef void (*SampleFunc)(int s);

// Viewport z alone: z in [-1, 1), scale and centre fixed (32768, 32768).
static void s_vp(int s) {
	point(s, frand(-1.0f, 1.0f));
}

// Viewport z scale and centre random per point (scale in [-40000, 40000),
// centre in [0, 65536)), z in [-1, 1).
static void s_vprand(int s) {
	float zs = frand(-40000.0f, 40000.0f), zc = frand(0.0f, 65536.0f);
	emit(VPZS, f24(zs));
	emit(VPZC, f24(zc));
	inputs[s * 4 + 1] = f24(zs);
	inputs[s * 4 + 2] = f24(zc);
	point(s, frand(-1.0f, 1.0f));
}

// The world matrix's z row: z' = m * z + t, m in [-4, 4), t in [-1, 1),
// z in [-1, 1). (View and projection identities.)
static void s_world(int s) {
	float m = frand(-4.0f, 4.0f), t = frand(-1.0f, 1.0f);
	emit(WORLDNUM, 8);
	emit(WORLDDATA, f24(m));
	emit(WORLDNUM, 11);
	emit(WORLDDATA, f24(t));
	inputs[s * 4 + 1] = f24(m);
	inputs[s * 4 + 2] = f24(t);
	point(s, frand(-1.0f, 1.0f));
}

// Perspective: the projection's w row takes z (w = a * z + b), x, y and z
// divided by it. a in [-1, 1), b in [1, 3), z in [-1, 1); the projection's z
// row stays z.
static void s_persp(int s) {
	float a = frand(-1.0f, 1.0f), b = frand(1.0f, 3.0f);
	emit(PROJNUM, 11);
	emit(PROJDATA, f24(a));
	emit(PROJNUM, 15);
	emit(PROJDATA, f24(b));
	inputs[s * 4 + 1] = f24(a);
	inputs[s * 4 + 2] = f24(b);
	point(s, frand(-1.0f, 1.0f));
}

// The view matrix's z column for z: z' = v * z + u, with world identity and
// a world z translation r: three operations in a row.
static void s_chain(int s) {
	float r = frand(-1.0f, 1.0f), v = frand(-2.0f, 2.0f), u = frand(-1.0f, 1.0f);
	emit(WORLDNUM, 11); emit(WORLDDATA, f24(r));
	emit(VIEWNUM, 8); emit(VIEWDATA, f24(v));
	emit(VIEWNUM, 11); emit(VIEWDATA, f24(u));
	inputs[s * 4 + 1] = f24(r);
	inputs[s * 4 + 2] = f24(v);
	inputs[s * 4 + 3] = f24(u);
	point(s, frand(-1.0f, 1.0f));
}

// Exact readouts: results in [0.5, 1) (points beyond the far plane are not
// drawn) with the viewport z at scale 65536 and centre -32768 give depth =
// (r - 0.5) * 65536, all the result's bits.
static void exactPort(void) {
	emit(VPZS, f24(65536.0f));
	emit(VPZC, f24(-32768.0f));
}

// The world z row's product alone: r = m * z, m and z in [0.71, 1) (z with
// all 24 bits; m a 24-bit float).
static void s_mul(int s) {
	if (s == 0)
		exactPort();
	float m = frand(0.71f, 1.0f);
	emit(WORLDNUM, 8);
	emit(WORLDDATA, f24(m));
	inputs[s * 4 + 1] = f24(m);
	point(s, frand(0.71f, 1.0f));
}

// The adder: r = z + t, z in [0.5, 0.95), t = +-2^-k * [0.5, 1) for k in
// 0..20 (results outside [0.5, 1) do not read out exactly).
static void s_add(int s) {
	if (s == 0)
		exactPort();
	float z = frand(0.5f, 0.95f);
	int k = next() % 21;
	float t = frand(0.5f, 1.0f) / (float)(1 << k);
	if (next() & 1)
		t = -t;
	emit(WORLDNUM, 11);
	emit(WORLDDATA, f24(t));
	inputs[s * 4 + 1] = f24(t);
	point(s, z);
}

// Multiply then add: r = m * z + t, m and z in [0.75, 0.9), t = +-2^-k *
// [0.5, 1) for k in 2..21.
static void s_madd(int s) {
	if (s == 0)
		exactPort();
	float m = frand(0.75f, 0.9f), z = frand(0.75f, 0.9f);
	int k = 2 + next() % 20;
	float t = frand(0.5f, 1.0f) / (float)(1 << k);
	if (next() & 1)
		t = -t;
	emit(WORLDNUM, 8); emit(WORLDDATA, f24(m));
	emit(WORLDNUM, 11); emit(WORLDDATA, f24(t));
	inputs[s * 4 + 1] = f24(m);
	inputs[s * 4 + 2] = f24(t);
	point(s, z);
}

// The dot product: r = mx * x + my * y + mz * z with x and y the point's own
// (small), mx, my in [-0.1, 0.1), mz and z in [0.75, 0.9).
static void s_dot(int s) {
	if (s == 0)
		exactPort();
	float mx = frand(-0.1f, 0.1f), my = frand(-0.1f, 0.1f), mz = frand(0.75f, 0.9f);
	emit(WORLDNUM, 2); emit(WORLDDATA, f24(mx));
	emit(WORLDNUM, 5); emit(WORLDDATA, f24(my));
	emit(WORLDNUM, 8); emit(WORLDDATA, f24(mz));
	inputs[s * 4 + 1] = f24(mx);
	inputs[s * 4 + 2] = f24(my);
	inputs[s * 4 + 3] = f24(mz);
	point(s, frand(0.75f, 0.9f));
}

// The reciprocal of w: w = b (the projection's w translation), z = 1 for b
// in [1, 2) and z = 2 for b in [2, 4), every 24-bit float b of those ranges
// in order, so the depth reads z / w exactly. x and y are scaled by b to
// keep the point on its pixel.
static void s_recip(int s) {
	if (s == 0)
		exactPort();
	float b = s < 32768 ? 1.0f + s / 32768.0f : 2.0f + (s - 32768) / 16384.0f;
	float z = s < 32768 ? 1.0f : 2.0f;
	emit(PROJNUM, 15);
	emit(PROJDATA, f24(b));
	inputs[s * 4 + 1] = f24(b);
	point(s, z);
	verts[s * 3] *= b;
	verts[s * 3 + 1] *= b;
}

static SceUID logFd = -1;

static void writeFile(const char *name, const void *p, int bytes) {
	char path[96];
	snprintf(path, sizeof(path), "host0:/xform/%s", name);
	SceUID fd = sceIoOpen(path, PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	if (fd >= 0) {
		sceIoWrite(fd, p, bytes);
		sceIoClose(fd);
	}
}

static void run(const char *name, SampleFunc sample) {
	memset(inputs, 0, sizeof(inputs));
	cmd = list;
	baseState();
	for (int s = 0; s < N; s++)
		sample(s);
	emit(0x0F, 0);
	emit(0x0C, 0);
	sceKernelDcacheWritebackAll();

	// Depth cleared to 0x1234 so untouched pixels show.
	sceGuStart(GU_DIRECT, setupList);
	sceGuClearColor(0);
	sceGuClearDepth(0x1234);
	sceGuClear(GU_COLOR_BUFFER_BIT | GU_DEPTH_BUFFER_BIT);
	sceGuFinish();
	sceGuSync(0, 0);
	int id = sceGeListEnQueue(list, cmd, -1, NULL);
	sceGeListSync(id, 0);

	static const unsigned int views[3] = { 0, 0x200000, 0x600000 };
	for (int v = 0; v < 3; v++) {
		const volatile unsigned short *src = (const volatile unsigned short *)(0x44000000 + views[v] + ZBUF);
		for (int i = 0; i < 512 * H; i++)
			depth[i] = src[i];
		char file[64];
		snprintf(file, sizeof(file), "%s_%d.bin", name, (int)(views[v] >> 20));
		writeFile(file, depth, sizeof(depth));
	}
	char file[64];
	snprintf(file, sizeof(file), "%s_in.bin", name);
	writeFile(file, inputs, sizeof(inputs));
	char line[96];
	snprintf(line, sizeof(line), "%s: %d samples\n", name, N);
	if (logFd >= 0)
		sceIoWrite(logFd, line, strlen(line));
	scePowerTick(PSP_POWER_TICK_ALL);
}

int main(int argc, char *argv[]) {
	sceIoMkdir("host0:/xform", 0777);
	logFd = sceIoOpen("host0:/__testoutput.txt", PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);

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

	run("vp", s_vp);
	run("vprand", s_vprand);
	run("world", s_world);
	run("persp", s_persp);
	run("chain", s_chain);
	run("mul", s_mul);
	run("add", s_add);
	run("madd", s_madd);
	run("dot", s_dot);
	run("recip", s_recip);

	sceGuTerm();
	if (logFd >= 0)
		sceIoClose(logFd);
	SceUID fin = sceIoOpen("host0:/__testfinish.txt", PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	if (fin >= 0) {
		sceIoWrite(fin, "1", 1);
		sceIoClose(fin);
	}
	sceKernelExitGame();
	return 0;
}
