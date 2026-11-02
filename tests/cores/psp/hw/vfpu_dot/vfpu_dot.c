// Records the VFPU dot product unit: vdot.q, vdot.t, vdot.p and vhdp.q of
// 1M pairs of vectors from a fixed xorshift sequence, in four kinds (see
// make_case): exponents spread wide, close together (cancellation), a matrix
// row times a point with w = 1, and values near 1.
//
// Run through PSPLink: host0:/dot/results.bin gets, per case, the four
// results (32-bit little endian); host0:/dot/inputs.bin the first block's
// inputs (eight words a case), to check the generator against. The
// generator uses integer operations only, so the PC can make the same inputs.
// host0:/__testfinish.txt is written at the end.

#include <pspkernel.h>
#include <pspiofilemgr.h>
#include <psppower.h>
#include <stdarg.h>
#include <stdio.h>

PSP_MODULE_INFO("VFPUDOT", 0, 1, 0);
PSP_MAIN_THREAD_ATTR(PSP_THREAD_ATTR_USER | PSP_THREAD_ATTR_VFPU);
PSP_HEAP_SIZE_KB(1024);

#define BLOCK 65536
#define BLOCKS 16
static unsigned int in[BLOCK * 8] __attribute__((aligned(64)));
static unsigned int out[BLOCK * 4] __attribute__((aligned(64)));

static unsigned int rng = 0x2545F491;

static unsigned int next(void) {
	rng ^= rng << 13;
	rng ^= rng >> 17;
	rng ^= rng << 5;
	return rng;
}

static unsigned int make(unsigned int sign, unsigned int expo, unsigned int mant) {
	return (sign << 31) | (expo << 23) | (mant & 0x7FFFFF);
}

// Eight words: a[0..3], b[0..3].
static void make_case(unsigned int k, unsigned int *v) {
	switch (k & 3) {
	case 0:
		for (int i = 0; i < 8; i++) {
			unsigned int r = next();
			v[i] = make(r >> 31, 112 + (r >> 8) % 31, next());
		}
		break;
	case 1: {
		unsigned int base = 118 + next() % 19;
		for (int i = 0; i < 8; i++) {
			unsigned int r = next();
			v[i] = make(r >> 31, base - 1 + (r >> 8) % 3, next());
		}
		break;
	}
	case 2:
		for (int i = 0; i < 4; i++) {
			unsigned int r = next();
			v[i] = make(r >> 31, 110 + (r >> 8) % 17, next());
		}
		for (int i = 4; i < 7; i++) {
			unsigned int r = next();
			v[i] = make(r >> 31, 120 + (r >> 8) % 16, next());
		}
		v[7] = 0x3F800000;
		break;
	default:
		for (int i = 0; i < 8; i++) {
			unsigned int r = next();
			v[i] = make(r >> 31, 124 + (r >> 8) % 7, next());
		}
		break;
	}
}

static void run(const unsigned int *p, unsigned int *q) {
	asm volatile(
		"lv.q C000, 0(%0)\n"
		"lv.q C010, 16(%0)\n"
		"vdot.q S100, C000, C010\n"
		"vdot.t S101, C000, C010\n"
		"vdot.p S102, C000, C010\n"
		"vhdp.q S103, C000, C010\n"
		"sv.q C100, 0(%1)\n"
		: : "r"(p), "r"(q) : "memory");
}

static int write_all(SceUID fd, const void *p, int bytes) {
	const char *c = (const char *)p;
	while (bytes > 0) {
		int n = sceIoWrite(fd, c, bytes);
		if (n <= 0)
			return -1;
		c += n;
		bytes -= n;
	}
	return 0;
}

int main(int argc, char *argv[]) {
	sceIoMkdir("host0:/dot", 0777);
	SceUID log = sceIoOpen("host0:/__testoutput.txt", PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	SceUID res = sceIoOpen("host0:/dot/results.bin", PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	SceUID inp = sceIoOpen("host0:/dot/inputs.bin", PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	u64 t0 = sceKernelGetSystemTimeWide();
	unsigned int k = 0;
	for (int b = 0; b < BLOCKS; b++) {
		for (int i = 0; i < BLOCK; i++, k++)
			make_case(k, in + i * 8);
		for (int i = 0; i < BLOCK; i++)
			run(in + i * 8, out + i * 4);
		if (b == 0)
			write_all(inp, in, sizeof(in));
		write_all(res, out, sizeof(out));
		scePowerTick(PSP_POWER_TICK_ALL);
	}
	sceIoClose(res);
	sceIoClose(inp);
	if (log >= 0) {
		char line[96];
		int n = snprintf(line, sizeof(line), "dot: %d cases, %.2f s\n", BLOCK * BLOCKS,
			(sceKernelGetSystemTimeWide() - t0) / 1000000.0);
		sceIoWrite(log, line, n);
		sceIoClose(log);
	}
	SceUID fin = sceIoOpen("host0:/__testfinish.txt", PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	if (fin >= 0) {
		sceIoWrite(fin, "1", 1);
		sceIoClose(fin);
	}
	sceKernelExitGame();
	return 0;
}
