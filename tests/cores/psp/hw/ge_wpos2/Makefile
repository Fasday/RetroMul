TARGET = ge_wpos2
OBJS = ge_wpos2.o

BUILD_PRX = 1
PSP_FW_VERSION = 500

CFLAGS = -O2 -G0 -Wall
CXXFLAGS = $(CFLAGS)
ASFLAGS = $(CFLAGS)
LIBS = -lpspgu -lpsppower -lpspge

PSPSDK = $(shell psp-config --pspsdk-path)
include $(PSPSDK)/lib/build.mak
