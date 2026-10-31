#!/bin/bash
# Builds the probe tests/cores/psp/hw/<probe> with the PSPDEV SDK in a copy
# outside the repository and copies the PRX to <out dir>.
#   build.sh <probe> <out dir>
set -e
probe=$1
out=$2
: "${PSPDEV:=$HOME/pspdev}"
export PSPDEV
export PATH="$PATH:$PSPDEV/bin"
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r "$here/$probe"/. "$work"/
make -C "$work" -s
mkdir -p "$out"
cp "$work/$probe.prx" "$out"/
