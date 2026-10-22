#!/bin/bash
# The love-mini package for the SD card: out/pkg/Roms/... and out/love-mini-<version>.zip.
#   build/package.sh            (after build/deps.sh and build/mini2d.sh)
# Inside: Roms/PORTS/Games/love-mini (LÖVE, its libraries, lovemini/, run.sh, the
# check game in games/check) and a Ports shortcut for the check game.
set -euo pipefail
. "$(dirname "$0")/env.sh"
VERSION=$(cat "$ROOT/VERSION")
STAGE=$ROOT/out/pkg
PKG=$STAGE/Roms/PORTS/Games/love-mini
ZIP=$ROOT/out/love-mini-$VERSION.zip
rm -rf "$STAGE" && mkdir -p "$PKG/bin" "$PKG/lib" "$PKG/games" "$PKG/profiles" "$PKG/licenses"

cp "$PREFIX/bin/love" "$PKG/bin/love"
cp "$PREFIX/lib/libmini2d.so" "$PREFIX/lib/libdspfix.so" "$PKG/lib/"

# diagnose (diag.sh): LuaJIT on its own, the screen through libmini2d alone, and
# glibc's libSegFault, which logs where a crash happened
cp "$PREFIX/bin/luajit" "$PKG/bin/luajit"
$CC -O2 $ARCHFLAGS "$ROOT/diag/m2dtest.c" -o "$PKG/bin/m2dtest" -L"$PKG/lib" -lmini2d -ldl -lpthread -Wl,-rpath-link,"$SYSROOT/usr/lib"
cp -L "$SYSROOT/lib/libSegFault.so" "$PKG/lib/"

# Every library LÖVE needs but glibc's and the Mini's own (MI_*, in /config/lib):
# from the build first, then the toolchain's sysroot.
SYSTEM=" libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 ld-linux-armhf.so.3 "
need() { ${CROSS}readelf -d "$1" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'; }
find_lib() {
    for d in "$PREFIX/lib" "$SYSROOT/usr/lib" "$SYSROOT/lib"; do
        [ -e "$d/$1" ] && { echo "$d/$1"; return; }
    done
    echo "package: $1 not found" >&2; exit 1
}
todo=("$PKG/bin/love" "$PKG/bin/luajit" "$PKG/lib/libmini2d.so")
while [ ${#todo[@]} -gt 0 ]; do
    f=${todo[0]}; todo=("${todo[@]:1}")
    for n in $(need "$f"); do
        case "$SYSTEM" in *" $n "*) continue ;; esac
        case "$n" in libmi_*) continue ;; esac
        [ -e "$PKG/lib/$n" ] && continue
        cp -L "$(find_lib "$n")" "$PKG/lib/$n"
        todo+=("$PKG/lib/$n")
    done
done
chmod 644 "$PKG"/lib/*
$STRIP "$PKG/bin/love" "$PKG/bin/luajit" "$PKG/bin/m2dtest" "$PKG"/lib/*.so*

cp -r "$ROOT/lovemini" "$PKG/lovemini"
rm -f "$PKG/lovemini/"*.orig
cp "$ROOT/pkg/run.sh" "$ROOT/pkg/diag.sh" "$ROOT/pkg/alsoft.conf" "$PKG/"
echo "$VERSION" > "$PKG/VERSION"
chmod +x "$PKG/run.sh" "$PKG/diag.sh" "$PKG"/bin/*
cp -r "$ROOT/demo/check" "$PKG/games/check"

cp "$ROOT/LICENSE" "$PKG/licenses/LICENSE-love-mini.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$PKG/licenses/"

# the check game in the Ports list (both names: OnionOS's "Import ports" prefers
# the .notfound copy and turns it into .port)
SC="$STAGE/Roms/PORTS/Shortcuts/LOVE games"
mkdir -p "$SC"
sed -e 's/@NAME@/love-mini check/' -e 's/@ID@/check/' "$ROOT/pkg/game.port" > "$SC/love-mini check.port"
cp "$SC/love-mini check.port" "$SC/love-mini check.notfound"
sed -e 's/@NAME@/love-mini diagnose/' -e 's/@ID@//' -e 's/^GameExecutable="run.sh"/GameExecutable="diag.sh"/' \
    "$ROOT/pkg/game.port" > "$SC/love-mini diagnose.port"
cp "$SC/love-mini diagnose.port" "$SC/love-mini diagnose.notfound"

# OpenAL Soft is LGPL: its source goes next to the zip, to attach to the release.
cp "$DEPS/src/openal-soft-1.21.1.tar.gz" "$ROOT/out/openal-soft-1.21.1-source.tar.gz"

rm -f "$ZIP"
python3 -I "$ROOT/tools/zipdir.py" "$ZIP" "$STAGE"
du -sh "$PKG"
ls "$PKG/lib"
ls -l "$ZIP"
