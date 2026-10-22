#!/bin/sh
# love-mini diagnose: checks love-mini piece by piece on this device and writes it all
# to diag.txt next to this script. A step that crashes leaves the place of the crash
# (libSegFault) and the steps after it still run.
#   1. the device: firmware, memory, screen, OnionOS libraries
#   2. libraries: what LOVE would load, and from where
#   3. LOVE starts at all (love --version)
#   4. LuaJIT runs and loads libmini2d
#   5. the screen through libmini2d alone (colour bars for ~3 s)
#   6. the check game, sound off (~3 s)
#   7. the check game, sound on (~3 s)
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
OUT="$DIR/diag.txt"
CRASH="$DIR/lib/libSegFault.so"
export SEGFAULT_SIGNALS="segv bus ill abrt fpe"
export LD_LIBRARY_PATH="$DIR/lib:/config/lib:/customer/lib:$LD_LIBRARY_PATH"
export LOVEMINI_DIR="$DIR"
export LOVEMINI_M2D="$DIR/lib/libmini2d.so"
export ALSOFT_CONF="$DIR/alsoft.conf"
export ALSOFT_LOGLEVEL=3
export SDL_VIDEODRIVER=dummy
export XDG_DATA_HOME="$DIR/saves"
export HOME="$DIR/saves"
mkdir -p "$DIR/saves"

step() { echo; echo "===== $*"; }

PADSP=""
for p in /mnt/SDCARD/miyoo/lib/libpadsp.so /customer/lib/libpadsp.so /mnt/SDCARD/.tmp_update/lib/libpadsp.so; do
  if [ -f "$p" ]; then PADSP="$p"; break; fi
done

{
  echo "love-mini $(cat "$DIR/VERSION" 2>/dev/null) diagnose, $(date)"

  step "1. device"
  cat /proc/version
  grep -E "Hardware|model name|Features" /proc/cpuinfo | sort -u
  free -m
  ls -l /lib/libc.so.6 /lib/ld-linux-armhf.so.3 /lib/libc-* 2>&1
  for f in virtual_size bits_per_pixel stride; do echo "fb0 $f: $(cat /sys/class/graphics/fb0/$f 2>&1)"; done
  ls /config/lib /customer/lib 2>&1 | grep -E "^/|mi_|padsp|SDL|stdc"
  echo "libpadsp: ${PADSP:-none}; audioserver: $(ps | grep -c [a]udioserver)"
  cat /mnt/SDCARD/.tmp_update/onionVersion/version.txt 2>/dev/null
  ps | grep -v "\[" | head -40

  step "2. libraries"
  LD_TRACE_LOADED_OBJECTS=1 "$DIR/bin/love" 2>&1
  echo "exit: $?"
  /lib/ld-linux-armhf.so.3 --list "$DIR/lib/libmini2d.so" 2>&1

  step "3. love --version"
  LD_PRELOAD="$CRASH" "$DIR/bin/love" --version 2>&1
  echo "exit: $?"

  step "4. LuaJIT and libmini2d"
  LD_PRELOAD="$CRASH" "$DIR/bin/luajit" -e 'io.stdout:setvbuf("no")
    print(jit.version, jit.arch, jit.os, jit.status())
    local s = 0
    for i = 1, 1e6 do s = s + i % 7 end
    print("loop", s)
    local ffi = require("ffi")
    ffi.cdef("void m2d_screen_size(int *w, int *h);")
    local m = ffi.load(os.getenv("LOVEMINI_M2D"))
    local w, h = ffi.new("int[1]"), ffi.new("int[1]")
    m.m2d_screen_size(w, h)
    print("libmini2d loaded, screen", w[0], h[0])' 2>&1
  echo "exit: $?"

  step "5. screen through libmini2d"
  LD_PRELOAD="$CRASH" "$DIR/bin/m2dtest" 2>&1
  echo "exit: $?"

  step "6. check game, sound off"
  LOVEMINI_TRACE=1 LOVEMINI_FRAMES=150 LOVEMINI_REPORT="$DIR/diag-report.json" LD_PRELOAD="$CRASH" \
    "$DIR/bin/love" "$DIR/games/check" 2>&1
  echo "exit: $?"
  cat "$DIR/diag-report.json" 2>/dev/null

  step "7. check game, sound on"
  if [ -n "$PADSP" ]; then
    LOVEMINI_TRACE=1 LOVEMINI_FRAMES=150 LD_PRELOAD="$CRASH $DIR/lib/libdspfix.so $PADSP" \
      "$DIR/bin/love" "$DIR/games/check" 2>&1
    echo "exit: $?"
  else
    echo "no libpadsp.so: skipped"
  fi

  step "end"
  free -m
} > "$OUT" 2>&1
sync
