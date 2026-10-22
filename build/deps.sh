#!/bin/bash
# Build LÖVE 11.5 and everything it needs for the Miyoo Mini, into .deps/arm/prefix.
#   build/deps.sh [step...]     (all steps by default; a step built before is skipped)
# Sources are downloaded into .deps/src and checked against build/sources.sha256
# (a source not listed there yet is added on its first download).
set -euo pipefail
. "$(dirname "$0")/env.sh"

SRC=$DEPS/src
WORK=$DEPS/work
STAMPS=$DEPS/stamps
SUMS=$ROOT/build/sources.sha256
mkdir -p "$SRC" "$WORK" "$STAMPS" "$PREFIX" "$DEPS/host"

# name|file|url
SOURCES='
pkgconf|pkgconf-2.3.0.tar.xz|https://distfiles.ariadne.space/pkgconf/pkgconf-2.3.0.tar.xz
sdl2|SDL2-2.30.9.tar.gz|https://github.com/libsdl-org/SDL/releases/download/release-2.30.9/SDL2-2.30.9.tar.gz
ogg|libogg-1.3.5.tar.gz|https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.gz
vorbis|libvorbis-1.3.7.tar.gz|https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz
theora|libtheora-1.1.1.tar.bz2|https://downloads.xiph.org/releases/theora/libtheora-1.1.1.tar.bz2
modplug|libmodplug-0.8.9.0.tar.gz|https://downloads.sourceforge.net/project/modplug-xmms/libmodplug/0.8.9.0/libmodplug-0.8.9.0.tar.gz
openal|openal-soft-1.21.1.tar.gz|https://github.com/kcat/openal-soft/archive/refs/tags/1.21.1.tar.gz
mpg123|mpg123-1.32.9.tar.bz2|https://www.mpg123.de/download/mpg123-1.32.9.tar.bz2
luajit|LuaJIT-a4c064539ea9.tar.gz|https://github.com/LuaJIT/LuaJIT/archive/a4c064539ea931274d407e1249b4bb575424a0f4.tar.gz
love|love-11.5-linux-src.tar.gz|https://github.com/love2d/love/releases/download/11.5/love-11.5-linux-src.tar.gz
'

log() { printf '\n== %s\n' "$*" >&2; }

# The source archive of `name`, downloaded and checked; its path.
fetch() {
    local line file url
    line=$(printf '%s\n' "$SOURCES" | grep "^$1|")
    file=$(echo "$line" | cut -d'|' -f2)
    url=$(echo "$line" | cut -d'|' -f3)
    if [ ! -f "$SRC/$file" ]; then
        curl -fsSL --retry 3 -o "$SRC/$file.part" "$url"
        mv "$SRC/$file.part" "$SRC/$file"
    fi
    local sum
    sum=$(sha256sum "$SRC/$file" | cut -d' ' -f1)
    if grep -q " $file\$" "$SUMS" 2>/dev/null; then
        grep -q "^$sum  $file\$" "$SUMS" || { echo "$file: checksum differs from build/sources.sha256" >&2; exit 1; }
    else
        echo "$sum  $file" >> "$SUMS"
    fi
    echo "$SRC/$file"
}

# Unpack `name`'s source afresh into .deps/work/<name>; cd there.
unpack() {
    local archive
    archive=$(fetch "$1")
    rm -rf "${WORK:?}/$1"
    mkdir -p "$WORK/$1"
    tar -xf "$archive" -C "$WORK/$1" --strip-components=1
    cd "$WORK/$1"
}

# Old configure scripts do not know arm-linux-gnueabihf: newer config.sub/guess.
fresh_config() {
    cp "$WORK/sdl2/build-scripts/config.sub" "$WORK/sdl2/build-scripts/config.guess" .
}

configure_arm() {
    ./configure --host=$HOSTTRIPLE --prefix="$PREFIX" --disable-static --enable-shared "$@"
}

step_pkgconf() {
    unpack pkgconf
    # This machine's compiler: pkgconf runs here.
    CC=gcc AR=ar RANLIB=ranlib CFLAGS=-O2 CPPFLAGS= LDFLAGS= ./configure --prefix="$DEPS/host" --disable-shared --enable-static >/dev/null
    make -j"$JOBS" AR=ar RANLIB=ranlib >/dev/null && make install >/dev/null
}

step_sdl2() {
    unpack sdl2
    # LÖVE needs SDL2 for events, timers and threads only: its window and graphics are
    # replaced (mini2d), its audio is OpenAL. A small SDL without video or audio drivers
    # but the dummy ones.
    configure_arm --disable-audio --disable-video-x11 --disable-video-wayland --disable-video-kmsdrm \
        --disable-video-opengl --disable-video-opengles --disable-video-opengles1 --disable-video-opengles2 \
        --disable-video-vulkan --disable-video-offscreen --disable-haptic --disable-sensor --disable-hidapi \
        --disable-joystick-virtual --disable-dbus --disable-ime --disable-ibus --disable-fcitx \
        --disable-libudev --disable-pulseaudio --disable-alsa --disable-sndio --disable-esd \
        --disable-pipewire --disable-jack --disable-arts --disable-nas --disable-oss >/dev/null
    make -j"$JOBS" >/dev/null && make install >/dev/null
}

step_ogg() {
    unpack ogg
    configure_arm >/dev/null && make -j"$JOBS" >/dev/null && make install >/dev/null
}

step_vorbis() {
    unpack vorbis
    configure_arm --with-ogg="$PREFIX" --disable-oggtest --disable-docs --disable-examples >/dev/null
    make -j"$JOBS" >/dev/null && make install >/dev/null
}

step_theora() {
    unpack theora
    fresh_config
    # 1.1.1's ARM assembly targets old assemblers: the C paths are enough here.
    configure_arm --with-ogg="$PREFIX" --with-vorbis="$PREFIX" --disable-oggtest --disable-vorbistest \
        --disable-examples --disable-encode --disable-asm --disable-spec --disable-doc >/dev/null
    make -j"$JOBS" >/dev/null && make install >/dev/null
}

step_modplug() {
    unpack modplug
    fresh_config
    configure_arm >/dev/null && make -j"$JOBS" >/dev/null && make install >/dev/null
}

step_openal() {
    unpack openal
    mkdir -p build && cd build
    # OSS only: the Mini's audio goes through OnionOS's libpadsp (/dev/dsp).
    "$CMAKE" .. -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm \
        -DCMAKE_C_COMPILER="${CROSS}gcc" -DCMAKE_CXX_COMPILER="${CROSS}g++" \
        -DCMAKE_SYSROOT="$SYSROOT" -DCMAKE_C_FLAGS="$CFLAGS" -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF -DALSOFT_TESTS=OFF -DALSOFT_INSTALL_CONFIG=OFF \
        -DALSOFT_INSTALL_HRTF_DATA=OFF -DALSOFT_INSTALL_AMBDEC_PRESETS=OFF \
        -DALSOFT_BACKEND_OSS=ON -DALSOFT_REQUIRE_OSS=ON -DALSOFT_BACKEND_ALSA=OFF -DALSOFT_BACKEND_PULSEAUDIO=OFF \
        -DALSOFT_BACKEND_PIPEWIRE=OFF -DALSOFT_BACKEND_JACK=OFF -DALSOFT_BACKEND_SNDIO=OFF \
        -DALSOFT_BACKEND_PORTAUDIO=OFF -DALSOFT_BACKEND_SDL2=OFF -DALSOFT_BACKEND_WAVE=ON >/dev/null
    make -j"$JOBS" >/dev/null && make install >/dev/null
}

step_mpg123() {
    unpack mpg123
    # MP3 for love.audio / love.sound (many games' music); the library only.
    configure_arm --with-cpu=neon --disable-components --enable-libmpg123 \
        --with-audio=dummy --with-default-audio=dummy >/dev/null
    make -j"$JOBS" >/dev/null && make install >/dev/null
}

step_luajit() {
    unpack luajit
    # buildvm runs here but makes code for a 32-bit target: a 32-bit compiler for this
    # machine is needed (zig's, with its own libc: no multilib packages).
    # The target's flags only where LuaJIT puts them (CFLAGS would reach the host build).
    CFLAGS= CPPFLAGS= LDFLAGS= make -j"$JOBS" HOST_CC="$ZIG cc -target x86-linux-musl" CROSS="$CROSS" \
        STATIC_CC="$CC" DYNAMIC_CC="$CC -fPIC" TARGET_LD="$CC" \
        TARGET_CFLAGS="$ARCHFLAGS" TARGET_SYS=Linux amalg >/dev/null
    make install PREFIX="$PREFIX" >/dev/null
}

step_love() {
    unpack love
    # One change: love-mini's boot runs before the game's conf.lua (lovemini/boot.lua).
    patch -p1 < "$ROOT/build/love-boot.patch"
    # LuaJIT's pkg-config file names its include folder by version.
    # The sysroot's pkg-config files say /usr: their flags given here instead, or the
    # build would take this machine's headers.
    configure_arm --with-lua=luajit --disable-gme \
        CPPFLAGS="$CPPFLAGS -I$PREFIX/include/luajit-2.1" \
        freetype2_CFLAGS="-I$SYSROOT/usr/include/freetype2" freetype2_LIBS="-lfreetype" \
        zlib_CFLAGS=" " zlib_LIBS="-lz" >/dev/null
    make -j"$JOBS" >/dev/null && make install >/dev/null
}

ALL="pkgconf sdl2 ogg vorbis theora modplug openal mpg123 luajit love"
for step in ${@:-$ALL}; do
    if [ -f "$STAMPS/$step" ] && [ $# -eq 0 ]; then
        continue
    fi
    log "$step"
    ( "step_$step" )
    touch "$STAMPS/$step"
done
log "done: $PREFIX"
