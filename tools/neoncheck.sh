#!/bin/bash
# The NEON rows of mini2d against its plain C: tests/scenes/blend drawn by both under
# qemu must be the same to the last pixel.
#   tools/neoncheck.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/build/env.sh"
OUT=$ROOT/out/neoncheck
rm -rf "$OUT" && mkdir -p "$OUT/neon" "$OUT/plain"
$CC -O2 -mcpu=cortex-a7 -mfpu=vfpv4 -mfloat-abi=hard -DM2D_HOST -fPIC -shared "$ROOT/mini2d/mini2d.c" \
    -o "$OUT/libmini2d_plain.so" -lm
for v in neon plain; do
    lib=$PREFIX/lib/libmini2d_host.so
    [ $v = plain ] && lib=$OUT/libmini2d_plain.so
    LOVEMINI_DIR=$ROOT LOVEMINI_M2D=$lib LOVEMINI_FRAMES=2 M2D_DUMP=$OUT/$v M2D_DUMP_EVERY=2 M2D_SIZE=640x480 \
        SDL_VIDEODRIVER=dummy XDG_DATA_HOME=$OUT HOME=$OUT LD_LIBRARY_PATH=$PREFIX/lib \
        qemu-arm -cpu cortex-a7 -L "$SYSROOT" "$PREFIX/bin/love" "$ROOT/tests/scenes/blend" > "$OUT/$v.log" 2>&1
done
if cmp -s "$OUT/neon/f000002.ppm" "$OUT/plain/f000002.ppm"; then
    echo "neoncheck: the same"
else
    echo "neoncheck: DIFFERENT (out/neoncheck/neon, out/neoncheck/plain)"; exit 1
fi
