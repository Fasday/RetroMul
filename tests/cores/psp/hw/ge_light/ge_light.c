// Records the GE's lighting arithmetic: one lit point per pixel, each with
// its own light and material registers, read back as 8888 pixels.
//
// Points are at world x = ((px - 240) * 2 + 1) / 512, y = ((136 - py) * 2 - 1)
// / 512, z = 0, normal (0, 0, 1); world, view and projection are identities
// and the viewport scales by 256, so a point lands on its pixel and its
// coordinates are exact 24-bit floats (a light can sit exactly above it).
//
// Each experiment is one frame: sample s is pixel (s % 480, s / 480). The
// frame goes to host0:/light/<name>.bin (272 rows of 512 words). Run through
// PSPLink; host0:/__testfinish.txt is written at the end.

#include <pspkernel.h>
#include <pspdisplay.h>
#include <pspge.h>
#include <pspgu.h>
#include <psppower.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

PSP_MODULE_INFO("GELIGHT", 0, 1, 0);
PSP_MAIN_THREAD_ATTR(PSP_THREAD_ATTR_USER | PSP_THREAD_ATTR_VFPU);
PSP_HEAP_SIZE_KB(1024);

#define W 480
#define H 272
#define SAMPLES (W * H)

static unsigned int __attribute__((aligned(64))) setupList[4096];
static unsigned int __attribute__((aligned(64))) list[SAMPLES * 10 + 4096];
static float __attribute__((aligned(64))) verts[SAMPLES * 6];
static unsigned int __attribute__((aligned(64))) frame[512 * H];

static unsigned int *cmd;

static void emit(unsigned int c, unsigned int arg) {
	*cmd++ = (c << 24) | (arg & 0xFFFFFF);
}

static unsigned int f24(float f) {
	union { float f; unsigned int u; } v;
	v.f = f;
	return v.u >> 8;
}

static float worldX(int px) { return (float)((px - 240) * 2 + 1) / 512.0f; }
static float worldY(int py) { return (float)((136 - py) * 2 - 1) / 512.0f; }

// GE command numbers.
enum {
	VADDR = 0x01, PRIM = 0x04, BASE = 0x10, VTYPE = 0x12, OFFSETADDR = 0x13,
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

// An identity matrix: 4x3 (rows of 3) or, with 16 values, 4x4.
static void identity(int num, int data, int n) {
	int cols = n == 16 ? 4 : 3;
	emit(num, 0);
	for (int i = 0; i < n; i++)
		emit(data, i / cols == i % cols ? f24(1.0f) : 0);
}

// The fixed state every experiment starts from.
static void baseState(void) {
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
	// Normal and position as floats.
	emit(VTYPE, (3 << 5) | (3 << 7));
	emit(LIGHTING, 1);
	for (int l = 0; l < 4; l++)
		emit(LIGHTENABLE0 + l, 0);
	emit(MATUPDATE, 0);
	emit(MATEMISSIVE, 0); emit(MATAMBIENT, 0xFFFFFF); emit(MATDIFFUSE, 0xFFFFFF);
	emit(MATSPECULAR, 0xFFFFFF); emit(MATALPHA, 0xFF); emit(MATSPECCOEF, f24(1.0f));
	emit(AMBIENTCOLOR, 0); emit(AMBIENTALPHA, 0xFF); emit(LIGHTMODE, 0);
	emit(LIGHTTYPE0, 0);
	emit(LX0, 0); emit(LX0 + 1, 0); emit(LX0 + 2, f24(1.0f));
	emit(LDX0, 0); emit(LDX0 + 1, 0); emit(LDX0 + 2, f24(1.0f));
	emit(LKA0, f24(1.0f)); emit(LKA0 + 1, 0); emit(LKA0 + 2, 0);
	emit(LKS0, f24(1.0f)); emit(LKO0, 0);
	emit(LAC0, 0); emit(LAC0 + 1, 0); emit(LAC0 + 2, 0);
}

static void pointN(int s, float nx, float ny, float nz) {
	int px = s % W, py = s / W;
	float *v = &verts[s * 6];
	v[0] = nx; v[1] = ny; v[2] = nz;
	v[3] = worldX(px); v[4] = worldY(py); v[5] = 0.0f;
	unsigned int a = (unsigned int)v;
	emit(BASE, (a >> 8) & 0x0F0000);
	emit(VADDR, a & 0xFFFFFF);
	emit(PRIM, (0 << 16) | 1);
}

static void point(int s) {
	pointN(s, 0.0f, 0.0f, 1.0f);
}

// A unit normal tilted from +z towards +x: its z is t.
static void pointTilt(int s, float t) {
	pointN(s, sqrtf(1.0f - t * t), 0.0f, t);
}

// A light 0 above sample s's point at height z.
static void lightAbove(int s, unsigned int zBits) {
	emit(LX0, f24(worldX(s % W)));
	emit(LX0 + 1, f24(worldY(s / W)));
	emit(LX0 + 2, zBits);
}

typedef void (*SampleFunc)(int s);

// Ambient products: a directional light with ambient (c, c, 255 - c) and the
// material ambient (m, m ^ 0x5A, m), all 65536 pairs.
static int amb_setup(void) {
	emit(LIGHTENABLE0, 1);
	emit(LIGHTTYPE0, 0);
	return 65536;
}
static void amb_sample(int s) {
	unsigned int c = s & 255, m = s >> 8;
	emit(LAC0, c | (c << 8) | ((255 - c) << 16));
	emit(MATAMBIENT, m | ((m ^ 0x5A) << 8) | (m << 16));
	point(s);
}

// Emissive plus global ambient times material ambient: emissive e (steps of
// 4), ambient a, material (255, 0x80, 0x33). No light on.
static int emis_setup(void) {
	emit(MATAMBIENT, 0xFF | (0x80 << 8) | (0x33 << 16));
	return 16384;
}
static void emis_sample(int s) {
	unsigned int a = s & 255, e = (s >> 8) * 4;
	emit(MATEMISSIVE, e | (e << 8) | (e << 16));
	emit(AMBIENTCOLOR, a | (a << 8) | (a << 16));
	point(s);
}

// Attenuation 1 / KA over every 24-bit float of [lo, 2 lo): a point light 1
// above the point, ambient (255, 0xC0, 0xA0).
static unsigned int kaBase;
static int att_setup(void) {
	emit(LIGHTENABLE0, 1);
	emit(LIGHTTYPE0, 1 << 8);
	emit(LAC0, 0xFF | (0xC0 << 8) | (0xA0 << 16));
	return 65536;
}
static void attka_sample(int s) {
	lightAbove(s, f24(1.0f));
	emit(LKA0, kaBase | s);
	emit(LKA0 + 1, 0);
	emit(LKA0 + 2, 0);
	point(s);
}
// Distance: the light at every 24-bit float height of [lo, 2 lo), with KB = 1
// (1 / d) or KC = 1 (1 / d^2).
static int kIndex;
static void attd_sample(int s) {
	lightAbove(s, kaBase | s);
	emit(LKA0, 0);
	emit(LKA0 + 1, kIndex == 1 ? f24(1.0f) : 0);
	emit(LKA0 + 2, kIndex == 2 ? f24(1.0f) : 0);
	point(s);
}

// The attenuation sweep with a material ambient other than white: in which
// order the attenuation, the light's and the material's colours multiply.
static int attm_setup(void) {
	att_setup();
	emit(MATAMBIENT, 0x80 | (0x33 << 8) | (0xF0 << 16));
	return 65536;
}

// Diffuse: a directional light along +z with diffuse (255, 0xC0, 0xA0) and
// no ambient; the normal tilted so N.L = t for 65536 t in (0, 1].
static unsigned int difMaterial;
static int dif_setup(void) {
	emit(LIGHTENABLE0, 1);
	emit(LIGHTTYPE0, 0);
	emit(LAC0 + 1, 0xFF | (0xC0 << 8) | (0xA0 << 16));
	emit(MATDIFFUSE, difMaterial);
	return 65536;
}
static void dif_sample(int s) {
	pointTilt(s, (float)(s + 1) / 65536.0f);
}

// Attenuation times diffuse: the point light 1 above, KA swept as in att_ka1,
// the normal tilted to N.L = 0.6 (the light's direction is +z).
static int difatt_setup(void) {
	emit(LIGHTENABLE0, 1);
	emit(LIGHTTYPE0, 1 << 8);
	emit(LAC0 + 1, 0xFF | (0xC0 << 8) | (0xA0 << 16));
	return 65536;
}
static void difatt_sample(int s) {
	lightAbove(s, f24(1.0f));
	emit(LKA0, f24(1.0f) | (s & 0x7FFF));
	emit(LKA0 + 1, 0);
	emit(LKA0 + 2, 0);
	pointTilt(s, 0.6f);
}

// A light's ambient plus its diffuse, and the sum's clamp: ambient (a, a, a)
// for a = s % 256, diffuse (255, 0xC0, 0x60) at N.L = (s / 256 + 1) / 256.
static int sum_setup(void) {
	emit(LIGHTENABLE0, 1);
	emit(LIGHTTYPE0, 0);
	return 65536;
}
static void sum_sample(int s) {
	unsigned int a = s & 255;
	emit(LAC0, a | (a << 8) | (a << 16));
	emit(LAC0 + 1, 0xFF | (0xC0 << 8) | (0x60 << 16));
	pointTilt(s, (float)((s >> 8) + 1) / 256.0f);
}

// Two directional lights' ambients: (a, a, a) and (b, b ^ 0x33, 255 - b).
static int two_setup(void) {
	emit(LIGHTENABLE0, 1);
	emit(LIGHTENABLE0 + 1, 1);
	emit(LIGHTTYPE0, 0);
	emit(LIGHTTYPE0 + 1, 0);
	emit(LX0 + 3, 0); emit(LX0 + 4, 0); emit(LX0 + 5, f24(1.0f));
	emit(LKA0 + 3, f24(1.0f)); emit(LKA0 + 4, 0); emit(LKA0 + 5, 0);
	emit(LAC0 + 4, 0); emit(LAC0 + 5, 0);
	emit(MATAMBIENT, 0xE0 | (0xE0 << 8) | (0xE0 << 16));
	return 65536;
}
static void two_sample(int s) {
	unsigned int a = s & 255, b = s >> 8;
	emit(LAC0, a | (a << 8) | (a << 16));
	emit(LAC0 + 3, b | ((b ^ 0x33) << 8) | ((255 - b) << 16));
	point(s);
}

// Attenuation of ambient plus diffuse: KA swept as in att_ka1, ambient
// (0x80, 0x81, 0x7F), diffuse (0x80, 0x40, 0xC0) at N.L = 0.6: whether the
// attenuation scales the terms or their sum.
static int attsum_setup(void) {
	difatt_setup();
	emit(LAC0, 0x80 | (0x81 << 8) | (0x7F << 16));
	emit(LAC0 + 1, 0x80 | (0x40 << 8) | (0xC0 << 16));
	return 65536;
}

// Spot factor: a spot light 1 above with ambient (FF, C0, A0), its direction
// (sqrt(1 - t^2), 0, t) for 65536 t in (0, 1] (the GE takes the cosine with
// the vector from the point to the light), cutoff -1, exponent spotExp.
static unsigned int spotExp;
static int spot_setup(void) {
	emit(LIGHTENABLE0, 1);
	emit(LIGHTTYPE0, 2 << 8);
	emit(LAC0, 0xFF | (0xC0 << 8) | (0xA0 << 16));
	emit(LKS0, spotExp);
	emit(LKO0, f24(-1.0f));
	return 65536;
}
static void spot_sample(int s) {
	float t = (float)(s + 1) / 65536.0f;
	lightAbove(s, f24(1.0f));
	emit(LDX0, f24(sqrtf(1.0f - t * t)));
	emit(LDX0 + 1, 0);
	emit(LDX0 + 2, f24(t));
	point(s);
}

// Spot cutoff: as spot (exponent 1) with the direction tilted to cos = 0.75
// and the cutoff swept over c = (s + 1) / 65536.
static int cut_setup(void) {
	spotExp = f24(1.0f);
	spot_setup();
	emit(LDX0, f24(sqrtf(1.0f - 0.75f * 0.75f)));
	emit(LDX0 + 1, 0);
	emit(LDX0 + 2, f24(0.75f));
	return 65536;
}
static void cut_sample(int s) {
	lightAbove(s, f24(1.0f));
	emit(LKO0, f24((float)(s + 1) / 65536.0f));
	point(s);
}

// Specular and powered diffuse: a directional light along +z, the normal
// tilted to N.L = N.H = t (the viewer is along +z), shininess shine.
// Specular (kind 1): specular colour (FF, C0, A0), no ambient or diffuse.
// Powered diffuse (kind 2): diffuse (FF, C0, A0).
static unsigned int shine, lightKind;
static int spec_setup(void) {
	emit(LIGHTENABLE0, 1);
	emit(LIGHTTYPE0, lightKind);
	emit(MATSPECCOEF, shine);
	if (lightKind == 1)
		emit(LAC0 + 2, 0xFF | (0xC0 << 8) | (0xA0 << 16));
	else
		emit(LAC0 + 1, 0xFF | (0xC0 << 8) | (0xA0 << 16));
	return 65536;
}

// Alpha: material alpha m and ambient alpha a, all pairs; the colour is the
// alpha product's too (emissive 0, global ambient (a, a, a), material ambient
// (m, m, m)).
static int alpha_setup(void) {
	return 65536;
}
static void alpha_sample(int s) {
	unsigned int a = s & 255, m = s >> 8;
	emit(AMBIENTCOLOR, a | (a << 8) | (a << 16));
	emit(AMBIENTALPHA, a);
	emit(MATAMBIENT, m | (m << 8) | (m << 16));
	emit(MATALPHA, m);
	point(s);
}

// Spot with attenuation: a spot light 1 above (cosine 0.6, exponent 1), KA
// swept as in att_ka1, with ambient (FF, C0, A0) (spotatt) or diffuse
// (FF, C0, A0) at N.L = 0.75 (spotdif).
static int spotDiffuse;
static int spotatt_setup(void) {
	emit(LIGHTENABLE0, 1);
	emit(LIGHTTYPE0, 2 << 8);
	emit(spotDiffuse ? LAC0 + 1 : LAC0, 0xFF | (0xC0 << 8) | (0xA0 << 16));
	emit(LKS0, f24(1.0f));
	emit(LKO0, f24(-1.0f));
	emit(LDX0, f24(0.8f));
	emit(LDX0 + 1, 0);
	emit(LDX0 + 2, f24(0.6f));
	return 65536;
}
static void spotatt_sample(int s) {
	lightAbove(s, f24(1.0f));
	emit(LKA0, f24(1.0f) | (s & 0x7FFF));
	emit(LKA0 + 1, 0);
	emit(LKA0 + 2, 0);
	if (spotDiffuse)
		pointTilt(s, 0.75f);
	else
		point(s);
}

// Specular with attenuation: a point light 1 above, specular (FF, C0, A0),
// shininess 2, the normal tilted to N.H = 0.8, KA swept.
static int specatt_setup(void) {
	emit(LIGHTENABLE0, 1);
	emit(LIGHTTYPE0, (1 << 8) | 1);
	emit(LAC0 + 2, 0xFF | (0xC0 << 8) | (0xA0 << 16));
	emit(MATSPECCOEF, f24(2.0f));
	return 65536;
}
static void specatt_sample(int s) {
	lightAbove(s, f24(1.0f));
	emit(LKA0, f24(1.0f) | (s & 0x7FFF));
	emit(LKA0 + 1, 0);
	emit(LKA0 + 2, 0);
	pointTilt(s, 0.8f);
}

static SceUID logFd = -1;

static void logline(const char *s) {
	if (logFd >= 0)
		sceIoWrite(logFd, s, strlen(s));
}

static void run(const char *name, int (*setup)(void), SampleFunc sample) {
	cmd = list;
	baseState();
	int n = setup();
	for (int s = 0; s < n && s < SAMPLES; s++)
		sample(s);
	emit(0x0F, 0);  // FINISH
	emit(0x0C, 0);  // END
	sceKernelDcacheWritebackAll();

	sceGuStart(GU_DIRECT, setupList);
	sceGuClearColor(0);
	sceGuClear(GU_COLOR_BUFFER_BIT);
	sceGuFinish();
	sceGuSync(0, 0);
	int id = sceGeListEnQueue(list, cmd, -1, NULL);
	sceGeListSync(id, 0);

	const unsigned int *vram = (const unsigned int *)0x44000000;
	for (int i = 0; i < 512 * H; i++)
		frame[i] = vram[i];
	char path[64];
	snprintf(path, sizeof(path), "host0:/light/%s.bin", name);
	SceUID fd = sceIoOpen(path, PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
	if (fd >= 0) {
		sceIoWrite(fd, frame, sizeof(frame));
		sceIoClose(fd);
	}
	char line[128];
	snprintf(line, sizeof(line), "%s: %d samples, %d list words\n", name, n, (int)(cmd - list));
	logline(line);
	scePowerTick(PSP_POWER_TICK_ALL);
}

int main(int argc, char *argv[]) {
	sceIoMkdir("host0:/light", 0777);
	logFd = sceIoOpen("host0:/__testoutput.txt", PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);

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

	run("amb", amb_setup, amb_sample);
	run("emis", emis_setup, emis_sample);
	kaBase = f24(1.0f); run("att_ka1", att_setup, attka_sample);
	kaBase = f24(2.0f); run("att_ka2", att_setup, attka_sample);
	kIndex = 1; kaBase = f24(1.0f); run("att_kb1", att_setup, attd_sample);
	kIndex = 1; kaBase = f24(2.0f); run("att_kb2", att_setup, attd_sample);
	kIndex = 2; kaBase = f24(1.0f); run("att_kc1", att_setup, attd_sample);
	kaBase = f24(1.0f); run("attm", attm_setup, attka_sample);
	difMaterial = 0xFFFFFF; run("dif", dif_setup, dif_sample);
	difMaterial = 0x80 | (0x33 << 8) | (0xF0 << 16); run("difm", dif_setup, dif_sample);
	run("difatt", difatt_setup, difatt_sample);
	run("sum", sum_setup, sum_sample);
	run("two", two_setup, two_sample);
	run("attsum", attsum_setup, difatt_sample);
	spotExp = f24(1.0f); run("spot_e1", spot_setup, spot_sample);
	spotExp = f24(2.0f); run("spot_e2", spot_setup, spot_sample);
	spotExp = f24(0.5f); run("spot_e05", spot_setup, spot_sample);
	spotExp = f24(10.0f); run("spot_e10", spot_setup, spot_sample);
	spotExp = f24(3.7f); run("spot_e37", spot_setup, spot_sample);
	run("cut", cut_setup, cut_sample);
	lightKind = 1; shine = f24(1.0f); run("spec_s1", spec_setup, dif_sample);
	lightKind = 1; shine = f24(2.0f); run("spec_s2", spec_setup, dif_sample);
	lightKind = 1; shine = f24(10.0f); run("spec_s10", spec_setup, dif_sample);
	lightKind = 1; shine = f24(0.5f); run("spec_s05", spec_setup, dif_sample);
	lightKind = 1; shine = f24(3.7f); run("spec_s37", spec_setup, dif_sample);
	lightKind = 2; shine = f24(1.0f); run("pdif_s1", spec_setup, dif_sample);
	lightKind = 2; shine = f24(10.0f); run("pdif_s10", spec_setup, dif_sample);
	run("alpha", alpha_setup, alpha_sample);
	spotDiffuse = 0; run("spotatt", spotatt_setup, spotatt_sample);
	spotDiffuse = 1; run("spotdif", spotatt_setup, spotatt_sample);
	run("specatt", specatt_setup, specatt_sample);

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
