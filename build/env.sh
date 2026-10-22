# The Miyoo Mini cross toolchain (GCC 8.3, glibc 2.28), used in place, and where the
# libraries built here go. Sourced by the build scripts.
#   . build/env.sh
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)
TC=${MIYOO_TOOLCHAIN:-$HOME/.local/opt/miyoomini-toolchain/rootfs/opt/miyoomini-toolchain}
export SYSROOT=$TC/usr/arm-linux-gnueabihf/sysroot
export HOSTTRIPLE=arm-linux-gnueabihf
export CROSS=$TC/usr/bin/arm-linux-gnueabihf-
# The sysroot given each time: the toolchain's own default is its bare libc, without
# the Mini's libraries (MI_GFX, MI_SYS, FreeType, zlib).
export CC="${CROSS}gcc --sysroot=$SYSROOT"
export CXX="${CROSS}g++ --sysroot=$SYSROOT"
# LÖVE links its program as Objective-C++ (for macOS): the same compiler.
export OBJCXX="$CXX"
export AR=${CROSS}ar RANLIB=${CROSS}ranlib STRIP=${CROSS}strip
export ARCHFLAGS="-mcpu=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard"
# Large-file support: without it, listing folders fails on the Mini's card.
export CFLAGS="-O2 $ARCHFLAGS -D_FILE_OFFSET_BITS=64 -D_LARGEFILE64_SOURCE"
export CXXFLAGS="$CFLAGS"
export DEPS=$ROOT/.deps
export PREFIX=$DEPS/arm/prefix
export CPPFLAGS="-I$PREFIX/include -I$SYSROOT/usr/include/freetype2"
export LDFLAGS="-L$PREFIX/lib -Wl,-rpath-link,$PREFIX/lib"
# pkg-config (pkgconf, built for this machine) looks only at our libraries and the
# sysroot's.
export PKG_CONFIG=$DEPS/host/bin/pkgconf
export PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig:$SYSROOT/usr/lib/pkgconfig
export PKG_CONFIG_SYSROOT_DIR=
export ZIG=${ZIG:-$HOME/.local/opt/zig/zig}
export CMAKE=${CMAKE:-$HOME/.local/opt/cmake/bin/cmake}
export JOBS=${JOBS:-$(nproc)}
