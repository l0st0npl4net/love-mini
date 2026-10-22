#!/bin/bash
# Run a LOVE game with love-mini off the device: the Mini's build of LOVE under qemu,
# drawing into memory; frames are saved as PNG and the report as JSON.
#   tools/run.sh GAME [FRAMES] [OUT] [INPUT]
# GAME: a folder or .love; FRAMES: frames to run (default 120); OUT: folder for the
# frames and report.json (default out/run/<game>); INPUT: a key script for mini2d
# ("frame code value" per line, evdev codes). Env: EVERY (save every Nth frame, 30),
# PROFILE (a profile.lua), SIZE (screen, 640x480), PADSP (OnionOS's libpadsp.so: sound
# goes the device's way, through libdspfix and libpadsp; with no audioserver here the
# game runs silent, but a crash on that way shows), LOVEMINI_DIR (another copy of
# lovemini/, to try a change), JITPROF / JITV (a file: LuaJIT's profile of the run /
# its trace log, see lovemini/boot.lua).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/build/env.sh"
GAME=$(realpath "$1")
FRAMES=${2:-120}
OUT=$(realpath -m "${3:-$ROOT/out/run/$(basename "${GAME%.love}")}")
INPUT=${4:-}
rm -rf "$OUT" && mkdir -p "$OUT/frames" "$OUT/save"
export LOVEMINI_DIR=${LOVEMINI_DIR:-$ROOT}
export LOVEMINI_M2D=$PREFIX/lib/libmini2d_host.so
export LOVEMINI_FRAMES=$FRAMES
export LOVEMINI_REPORT=$OUT/report.json
export LOVEMINI_PROFILE=${PROFILE:+$(realpath "$PROFILE")}
export M2D_DUMP=$OUT/frames M2D_DUMP_EVERY=${EVERY:-30} M2D_SIZE=${SIZE:-640x480}
[ -n "$INPUT" ] && export M2D_INPUT=$(realpath "$INPUT")
PADSP=${PADSP:+$(realpath "$PADSP")}
[ -n "${JITV:-}" ] && export LOVEMINI_JITV=$(realpath -m "$JITV")
if [ -n "${JITPROF:-}${JITV:-}" ]; then
    [ -n "${JITPROF:-}" ] && export LOVEMINI_JITPROF=$(realpath -m "$JITPROF")
    PRELOAD_LUA=(-E "LUA_PATH=$(echo "$PREFIX"/share/luajit-2.1*)/?.lua;;")
else
    PRELOAD_LUA=()
fi
export SDL_VIDEODRIVER=dummy XDG_DATA_HOME=$OUT/save HOME=$OUT/save
export LD_LIBRARY_PATH=$PREFIX/lib
# from the game's folder, as run.sh on the Mini (some games open files by relative path)
[ -d "$GAME" ] && cd "$GAME" || cd "$(dirname "$GAME")"
PRELOAD=()
[ -n "${PADSP:-}" ] && PRELOAD=(-E "LD_PRELOAD=$PREFIX/lib/libdspfix.so $PADSP")
qemu-arm -cpu cortex-a7 -L "$SYSROOT" "${PRELOAD[@]}" "${PRELOAD_LUA[@]}" "$PREFIX/bin/love" "$GAME" 2>&1 | tee "$OUT/log.txt" | grep -v "Could not open device" || true
python3 "$ROOT/tools/ppm2png.py" "$OUT/frames"
echo "frames: $OUT/frames, report: $OUT/report.json"
