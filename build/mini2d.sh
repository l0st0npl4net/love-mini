#!/bin/bash
# Build libmini2d (and libdspfix): for the Mini (MI_GFX present), for the Mini as a host stub (runs
# under qemu: frames dumped, keys from a script), and for this machine.
#   build/mini2d.sh            -> .deps/arm/prefix/lib/libmini2d.so, libmini2d_host.so; out/host/libmini2d_host.so
set -e
. "$(dirname "$0")/env.sh"
SRC=$ROOT/mini2d/mini2d.c
mkdir -p "$PREFIX/lib" "$ROOT/out/host"
W="-Wall -Wextra -Wno-unused-parameter"
$CC -O3 $ARCHFLAGS -fPIC -shared $W "$SRC" -o "$PREFIX/lib/libmini2d.so" -lmi_gfx -lmi_sys -lmi_common -lpthread -lm
$CC -O2 $ARCHFLAGS -DM2D_HOST -fPIC -shared $W "$SRC" -o "$PREFIX/lib/libmini2d_host.so" -lm
gcc -O2 -g -DM2D_HOST -fPIC -shared $W "$SRC" -o "$ROOT/out/host/libmini2d_host.so" -lm
# libdspfix: OpenAL's /dev/dsp to OnionOS's libpadsp
$CC -O2 $ARCHFLAGS -fPIC -shared $W -Wno-nonnull-compare "$ROOT/dspfix/dspfix.c" -o "$PREFIX/lib/libdspfix.so" -ldl
echo "libdspfix: $PREFIX/lib/libdspfix.so"
echo "libmini2d: $PREFIX/lib/libmini2d.so, libmini2d_host.so (ARM stub), out/host/libmini2d_host.so"
