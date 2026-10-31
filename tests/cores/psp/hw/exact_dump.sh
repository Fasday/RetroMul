#!/bin/bash
# Builds pspautotests' gpu/exact/<test> in a copy outside the repository with
# a job runner that also writes each job's readback to
# host0:/exact/<test>_<job>.bin (rows of 512 pixels), and copies the PRX to
# <out dir>/exact_<test>.prx. The test's sources and .expected stay as they
# are.
#   exact_dump.sh <test> <out dir>
set -e
test=$1
out=$2
: "${PSPDEV:=$HOME/pspdev}"
export PSPDEV
export PATH="$PATH:$PSPDEV/bin"
here=$(cd "$(dirname "$0")" && pwd)
src="$here/../run/pspautotests"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tests/gpu"
cp -r "$src/common" "$work/common"
cp -r "$src/tests/gpu/exact" "$work/tests/gpu/exact"
cp -r "$src/tests/dmac" "$work/tests/dmac"
find "$work" -name '*.prx' -delete
make -C "$work/common" -s >/dev/null
cd "$work/tests/gpu/exact"
DUMP_NAME="$test" python3 - <<'EOF'
import os
p = 'jobs.cpp'
s = open(p).read()
old = '\t\tprintf("%s: %08x\\n", jobs[j].name, (unsigned int)crc);'
assert old in s
s = s.replace(old, old + '''
		{
			char path[96];
			snprintf(path, sizeof(path), "host0:/exact/%s_%d.bin", DUMP_NAME, (int)j);
			SceUID fd = sceIoOpen(path, PSP_O_CREAT | PSP_O_WRONLY | PSP_O_TRUNC, 0777);
			if (fd >= 0) {
				sceIoWrite(fd, readBuf, rows * 512 * bpp);
				sceIoClose(fd);
			}
		}''')
s = s.replace('#include "jobs.h"', '#include "jobs.h"\n#include <pspiofilemgr.h>\n#include <stdio.h>\n#define DUMP_NAME "' + os.environ['DUMP_NAME'] + '"', 1)
s = s.replace('\tinitDisplay();', '\tsceIoMkdir("host0:/exact", 0777);\n\tinitDisplay();', 1)
open(p, 'w').write(s)
EOF
make -C ../../dmac -s dmac-imports.o
make -s TARGETS="$test"
mkdir -p "$out"
cp "$test.prx" "$out/exact_$test.prx"
