// Records the VFPU function unit's results over whole input ranges, for
// fitting its algorithms: every mantissa of one or two exponents (vrcp, vrsq,
// vsqrt, vlog2), every step of the 23-fraction-bit fixed point the angle,
// exponent and arcsine inputs are taken in (vsin, vcos, vexp2, vasin), and
// random bit patterns through every function.
//
// Run through PSPLink: host0:/sweep/<name>.bin gets the 32-bit results in
// input order (little endian); random.bin gets each input followed by the
// results of the functions in the order of RandomOps. argv[1] picks one sweep,
// none runs them all. host0:/__testfinish.txt is written at the end.

#include <pspkernel.h>
#include <pspiofilemgr.h>
#include <psppower.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

PSP_MODULE_INFO("VFPUSWEEP", 0, 1, 0);
PSP_MAIN_THREAD_ATTR(PSP_THREAD_ATTR_USER | PSP_THREAD_ATTR_VFPU);
PSP_HEAP_SIZE_KB(1024);

#define CHUNK (1 << 20)
static unsigned int buf[CHUNK] __attribute__((aligned(64)));
static unsigned int inputs[CHUNK / 16] __attribute__((aligned(64)));

#define APPLY(name, instr) \
	static void name(unsigned int *p, int n) { \
		for (int i = 0; i < n; i += 4) { \
			asm volatile( \
				"lv.q C000, 0(%0)\n" \
				instr " C100, C000\n" \
				"sv.q C100, 0(%0)\n" \
				: : "r"(p + i) : "memory"); \
		} \
	}

APPLY(do_rcp, "vrcp.q")
APPLY(do_rsq, "vrsq.q")
APPLY(do_sqrt, "vsqrt.q")
APPLY(do_sin, "vsin.q")
APPLY(do_cos, "vcos.q")
APPLY(do_nsin, "vnsin.q")
APPLY(do_asin, "vasin.q")
APPLY(do_exp2, "vexp2.q")
APPLY(do_rexp2, "vrexp2.q")
APPLY(do_log2, "vlog2.q")
APPLY(do_nrcp, "vnrcp.q")

typedef void (*ApplyFunc)(unsigned int *, int);

static unsigned int float_bits(float f) {
	union { float f; unsigned int u; } v;
	v.f = f;
	return v.u;
}

// Input generators: index -> input bits.
static unsigned int gen_m1(unsigned int i) { return 0x3F800000 | i; }     // [1, 2)
static unsigned int gen_m2(unsigned int i) { return 0x40000000 | i; }     // [2, 4)
static unsigned int gen_mh(unsigned int i) { return 0x3F000000 | i; }     // [0.5, 1)
static unsigned int gen_fix(unsigned int i) { return float_bits((float)i * (1.0f / 8388608.0f)); }    // i / 2^23
static unsigned int gen_nfix(unsigned int i) { return float_bits(-(float)i * (1.0f / 8388608.0f)); }  // -i / 2^23

static const struct {
	const char *name;
	ApplyFunc apply;
	unsigned int (*gen)(unsigned int);
} sweeps[] = {
	{ "rcp_m1", do_rcp, gen_m1 },
	{ "rsq_m1", do_rsq, gen_m1 },
	{ "rsq_m2", do_rsq, gen_m2 },
	{ "sqrt_m1", do_sqrt, gen_m1 },
	{ "sqrt_m2", do_sqrt, gen_m2 },
	{ "log2_m1", do_log2, gen_m1 },
	{ "log2_mh", do_log2, gen_mh },
	{ "exp2_fix", do_exp2, gen_fix },
	{ "exp2_nfix", do_exp2, gen_nfix },
	{ "sin_fix", do_sin, gen_fix },
	{ "cos_fix", do_cos, gen_fix },
	{ "asin_fix", do_asin, gen_fix },
};

static const struct { const char *name; ApplyFunc apply; } RandomOps[] = {
	{ "rcp", do_rcp }, { "rsq", do_rsq }, { "sqrt", do_sqrt }, { "sin", do_sin }, { "cos", do_cos },
	{ "nsin", do_nsin }, { "asin", do_asin }, { "exp2", do_exp2 }, { "rexp2", do_rexp2 },
	{ "log2", do_log2 }, { "nrcp", do_nrcp },
};

static SceUID logFd = -1;

static void logf_(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logf_(const char *fmt, ...) {
	char line[256];
	va_list ap;
	va_start(ap, fmt);
	int n = vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	if (logFd >= 0 && n > 0)
		sceIoWrite(logFd, line, n);
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

static SceUID open_out(const char *name) {
	char path[96];
	snprintf(path, sizeof(path), "host0:/sweep/%s.bin", name);
	return sceIoOpen(path, PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
}

static void run_sweep(int s) {
	u64 t0 = sceKernelGetSystemTimeWide();
	SceUID fd = open_out(sweeps[s].name);
	if (fd < 0) {
		logf_("%s: open failed %08x\n", sweeps[s].name, fd);
		return;
	}
	u64 compute = 0;
	for (unsigned int base = 0; base < (1u << 23); base += CHUNK) {
		for (unsigned int i = 0; i < CHUNK; i++)
			buf[i] = sweeps[s].gen(base + i);
		u64 c0 = sceKernelGetSystemTimeWide();
		sweeps[s].apply(buf, CHUNK);
		compute += sceKernelGetSystemTimeWide() - c0;
		if (write_all(fd, buf, sizeof(buf)) < 0) {
			logf_("%s: write failed at %u\n", sweeps[s].name, base);
			break;
		}
		// Long runs without input: keep the PSP from sleeping.
		scePowerTick(PSP_POWER_TICK_ALL);
	}
	sceIoClose(fd);
	logf_("%s: %u values, %.2f s (%.3f s computing)\n", sweeps[s].name, 1u << 23,
		(sceKernelGetSystemTimeWide() - t0) / 1000000.0, compute / 1000000.0);
}

// 1M random bit patterns (a fixed xorshift sequence), in blocks of 64K: each
// block's inputs, then each function's results for them.
static void run_random(void) {
	u64 t0 = sceKernelGetSystemTimeWide();
	SceUID fd = open_out("random");
	if (fd < 0) {
		logf_("random: open failed %08x\n", fd);
		return;
	}
	unsigned int x = 0x12345678;
	const int block = CHUNK / 16;
	for (int b = 0; b < 16; b++) {
		for (int i = 0; i < block; i++) {
			x ^= x << 13;
			x ^= x >> 17;
			x ^= x << 5;
			inputs[i] = x;
		}
		write_all(fd, inputs, block * 4);
		for (int o = 0; o < (int)(sizeof(RandomOps) / sizeof(RandomOps[0])); o++) {
			memcpy(buf, inputs, block * 4);
			RandomOps[o].apply(buf, block);
			write_all(fd, buf, block * 4);
		}
	}
	sceIoClose(fd);
	logf_("random: %d values x %d functions, %.2f s\n", CHUNK, (int)(sizeof(RandomOps) / sizeof(RandomOps[0])),
		(sceKernelGetSystemTimeWide() - t0) / 1000000.0);
}

int main(int argc, char *argv[]) {
	sceIoMkdir("host0:/sweep", 0777);
	logFd = sceIoOpen("host0:/__testoutput.txt", PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	const char *only = argc > 1 ? argv[1] : NULL;
	for (int s = 0; s < (int)(sizeof(sweeps) / sizeof(sweeps[0])); s++)
		if (only == NULL || strcmp(only, sweeps[s].name) == 0)
			run_sweep(s);
	if (only == NULL || strcmp(only, "random") == 0)
		run_random();
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
