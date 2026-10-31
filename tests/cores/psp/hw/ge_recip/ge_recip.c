// Records the GE's reciprocal of a triangle's area (the depth plane's
// 1/area, a function of the area's top 17 bits) for every one of the 2^16
// mantissas: through-mode strip triangles 480 pixels wide and up to 4.3
// pixels tall, 60 a frame, triangle k of frame f with the area
// (2^16 + 60 f + k) * 4 (1/16 pixel squared), depth rising from 2000 to
// 62000 across it. The depth buffer is read back through VRAM's linear
// view (host0:/recip/frame_<n>.bin, 272 rows of 480 16-bit values, cleared
// to 0); the triangles follow from the numbers: vertices (0, B, 2000),
// (7680, B - 1, 62000), (r, B + h, 2000 + 60000 r / 7680) in 1/16 pixel,
// B = 72 k + 8, h = A / 7680, r = A mod 7680.

#include <pspkernel.h>
#include <pspge.h>
#include <pspgu.h>
#include <psppower.h>
#include <stdio.h>
#include <string.h>

PSP_MODULE_INFO("GERECIP", 0, 1, 0);
PSP_MAIN_THREAD_ATTR(PSP_THREAD_ATTR_USER | PSP_THREAD_ATTR_VFPU);
PSP_HEAP_SIZE_KB(1024);

#define W 480
#define H 272
#define ZBUF 0x88000
#define STRIPS 60
#define FRAMES ((65536 + STRIPS - 1) / STRIPS)

typedef struct {
	unsigned int color;
	float x, y, z;
} Vertex;

static unsigned int __attribute__((aligned(64))) setupList[4096];
static unsigned int __attribute__((aligned(64))) list[4096];
static Vertex __attribute__((aligned(64))) verts[STRIPS * 3];
static unsigned short __attribute__((aligned(64))) depth[W * H];

static unsigned int *cmd;

static void emit(unsigned int c, unsigned int arg) {
	*cmd++ = (c << 24) | (arg & 0xFFFFFF);
}

enum {
	VADDR = 0x01, PRIM = 0x04, BASE = 0x10, VTYPE = 0x12, LIGHTING = 0x17, CLIPENABLE = 0x1C, CULLENABLE = 0x1D,
	TEXENABLE = 0x1E, FOGENABLE = 0x1F, DITHERENABLE = 0x20, BLENDENABLE = 0x21, ALPHATEST = 0x22, ZTESTEN = 0x23,
	STENCILTEST = 0x24, ANTIALIAS = 0x25, COLORTEST = 0x27, LOGICOP = 0x28, SHADEMODE = 0x50,
	ZBUFPTR = 0x9E, ZBUFWIDTH = 0x9F, MINZ = 0xD6, MAXZ = 0xD7, ZTEST = 0xDE, ZWRITEDISABLE = 0xE7,
	MASKRGB = 0xE8, MASKALPHA = 0xE9,
};

static SceUID openOut(const char *name) {
	char path[96];
	snprintf(path, sizeof(path), "host0:/recip/%s", name);
	return sceIoOpen(path, PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
}

static void frame(int f) {
	for (int k = 0; k < STRIPS; k++) {
		int m = f * STRIPS + k;
		Vertex *v = &verts[k * 3];
		if (m >= 65536) {
			memset(v, 0, sizeof(Vertex) * 3);
			continue;
		}
		int A = (65536 + m) * 4;
		int h = A / 7680, r = A % 7680;
		int B = 72 * k + 8;
		v[0].color = 0xFFFFFFFF; v[0].x = 0; v[0].y = B / 16.0f; v[0].z = 2000;
		v[1].color = 0xFFFFFFFF; v[1].x = 7680 / 16.0f; v[1].y = (B - 1) / 16.0f; v[1].z = 62000;
		v[2].color = 0xFFFFFFFF; v[2].x = r / 16.0f; v[2].y = (B + h) / 16.0f; v[2].z = (float)(2000 + 60000 * r / 7680);
	}
	sceKernelDcacheWritebackAll();

	sceGuStart(GU_DIRECT, setupList);
	sceGuClearDepth(0);
	sceGuClearColor(0);
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
	emit(VTYPE, (1 << 23) | (3 << 7) | (7 << 2));
	unsigned int a = (unsigned int)verts;
	emit(BASE, (a >> 8) & 0x0F0000);
	emit(VADDR, a & 0xFFFFFF);
	emit(PRIM, (3 << 16) | (STRIPS * 3));
	emit(0x0F, 0);
	emit(0x0C, 0);
	sceKernelDcacheWritebackAll();
	int id = sceGeListEnQueue(list, cmd, -1, NULL);
	sceGeListSync(id, 0);

	const volatile unsigned short *src = (const volatile unsigned short *)(0x44000000 + 0x600000 + ZBUF);
	for (int y = 0; y < H; y++)
		for (int x = 0; x < W; x++)
			depth[y * W + x] = src[y * 512 + x];
	char file[64];
	snprintf(file, sizeof(file), "frame_%04d.bin", f);
	SceUID fd = openOut(file);
	if (fd >= 0) {
		sceIoWrite(fd, depth, sizeof(depth));
		sceIoClose(fd);
	}
	scePowerTick(PSP_POWER_TICK_ALL);
}

int main(int argc, char *argv[]) {
	sceIoMkdir("host0:/recip", 0777);
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

	int first = 0, last = FRAMES;
	if (argc > 1) {
		// "first-last" frames, for partial runs.
		sscanf(argv[1], "%d-%d", &first, &last);
	}
	for (int f = first; f < last && f < FRAMES; f++)
		frame(f);

	if (logFd >= 0) {
		sceIoWrite(logFd, "recip: done\n", 12);
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
