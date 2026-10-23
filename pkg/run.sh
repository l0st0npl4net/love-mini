#!/bin/sh
# love-mini: a LÖVE 11.5 game on the Miyoo Mini (OnionOS).
#   run.sh <id>     the game in games/<id>/: game.love, another .love or .exe, or a
#                   folder with main.lua; its profile games/<id>/profile.lua (next
#                   to a .love) or profiles/<id>.lua, if there is one.
#   run.sh <id> jit=off   the same with LuaJIT's compiler off (to compare)
# The log goes to games/<id>/log.txt (the run before: log.prev.txt).
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
ID="$1"
JITOPT=""
[ "$2" = "jit=off" ] && JITOPT=off
GAMEDIR="$DIR/games/$ID"

if [ -z "$ID" ] || [ ! -d "$GAMEDIR" ]; then
  echo "love-mini: no game \"$ID\" in $DIR/games" > /tmp/MissingPortFile.tmp
  exit 1
fi

GAME=""
if [ -f "$GAMEDIR/game.love" ]; then
  GAME="$GAMEDIR/game.love"
else
  for f in "$GAMEDIR"/*.love "$GAMEDIR"/*.exe "$GAMEDIR"/*.LOVE "$GAMEDIR"/*.EXE; do
    if [ -f "$f" ]; then GAME="$f"; break; fi
  done
fi
[ -z "$GAME" ] && [ -f "$GAMEDIR/main.lua" ] && GAME="$GAMEDIR"
if [ -z "$GAME" ]; then
  echo "love-mini: games/$ID has no game.love\n(put the game's .love or .exe there)" > /tmp/MissingPortFile.tmp
  exit 1
fi

# (games/<id>/profile.lua only next to a .love: a game's own folder may have a file of that name)
PROFILE=""
if [ "$GAME" != "$GAMEDIR" ] && [ -f "$GAMEDIR/profile.lua" ]; then
  PROFILE="$GAMEDIR/profile.lua"
elif [ -f "$DIR/profiles/$ID.lua" ]; then
  PROFILE="$DIR/profiles/$ID.lua"
fi

LOG="$GAMEDIR/log.txt"
[ -f "$LOG" ] && mv "$LOG" "$GAMEDIR/log.prev.txt"
{
  echo "===== love-mini $(cat "$DIR/VERSION" 2>/dev/null): $ID $(date)"
  echo "game: $GAME"
  echo "profile: ${PROFILE:-none}"
  free -m
} > "$LOG" 2>&1

CPU=/sys/devices/system/cpu/cpu0/cpufreq
OLD_GOV="$(cat $CPU/scaling_governor 2>/dev/null)"
echo performance 2>/dev/null > $CPU/scaling_governor
# The profile's cpu_mhz (a plain number: cpu_mhz = 1500): the clock OnionOS's cpuclock
# sets, as RetroArch's cores have it; put back after the game.
CPUCLOCK=/mnt/SDCARD/.tmp_update/bin/cpuclock
MHZ=""
[ -n "$PROFILE" ] && MHZ="$(sed -n 's/^[[:space:]]*cpu_mhz[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$PROFILE" | head -n 1)"
OLD_MHZ=""
if [ -n "$MHZ" ] && [ -x "$CPUCLOCK" ]; then
  OLD_MHZ="$("$CPUCLOCK" 2>/dev/null)"
  echo "cpu: $("$CPUCLOCK" "$MHZ" 2>&1 | tail -n 1) MHz (was $OLD_MHZ)" >> "$LOG"
fi

# Saves where OnionOS keeps them (they outlive updates of love-mini and the game).
SAVES=/mnt/SDCARD/Saves/CurrentProfile/saves/love-mini
mkdir -p "$SAVES" 2>/dev/null || SAVES="$DIR/saves"
mkdir -p "$SAVES"
export XDG_DATA_HOME="$SAVES"
export HOME="$SAVES"

export LOVEMINI_DIR="$DIR"
export LOVEMINI_M2D="$DIR/lib/libmini2d.so"
export LOVEMINI_PROFILE="$PROFILE"
[ "$JITOPT" = off ] && export LOVEMINI_JIT=0
# The compatibility report (missing functions, shaders, errors, frame times):
# export LOVEMINI_REPORT="$GAMEDIR/report.json"
# Each step of the start in the log:
# export LOVEMINI_TRACE=1

# Sound: OnionOS plays OSS (/dev/dsp) through its audioserver when libpadsp.so is
# preloaded; libdspfix sends OpenAL's open64("/dev/dsp") to libpadsp's open().
# libSegFault: if the game crashes, where it crashed goes to the log.
export LD_PRELOAD="$DIR/lib/libSegFault.so"
export SEGFAULT_SIGNALS="segv bus ill abrt fpe"
for p in /mnt/SDCARD/miyoo/lib/libpadsp.so /customer/lib/libpadsp.so /mnt/SDCARD/.tmp_update/lib/libpadsp.so; do
  if [ -f "$p" ]; then LD_PRELOAD="$LD_PRELOAD $DIR/lib/libdspfix.so $p"; break; fi
done
echo "audio: LD_PRELOAD=${LD_PRELOAD:-none} audioserver=$(ps | grep -c [a]udioserver)" >> "$LOG"
export ALSOFT_CONF="$DIR/alsoft.conf"
export ALSOFT_LOGLEVEL=1
export SDL_VIDEODRIVER=dummy
export LD_LIBRARY_PATH="$DIR/lib:/config/lib:/customer/lib:$LD_LIBRARY_PATH"

cd "$GAMEDIR"
"$DIR/bin/love" "$GAME" >> "$LOG" 2>&1
CODE=$?
echo "love exited with code $CODE" >> "$LOG"

# One line per run in runs.txt (all games): enough to tell how each went.
{
  echo "$(date '+%Y-%m-%d %H:%M') $ID${JITOPT:+ (jit off)} love-mini $(cat "$DIR/VERSION" 2>/dev/null) exit $CODE"
  grep -m 1 -E "^Error|Segmentation fault" "$LOG" | sed 's/^/    /'
  grep "love-mini: frames:" "$LOG" | tail -n 1 | sed 's/^love-mini: /    last /'
} >> "$DIR/runs.txt"
free -m >> "$LOG" 2>&1

[ -n "$OLD_MHZ" ] && "$CPUCLOCK" "$OLD_MHZ" > /dev/null 2>&1
[ -n "$OLD_GOV" ] && echo "$OLD_GOV" 2>/dev/null > $CPU/scaling_governor
sync
