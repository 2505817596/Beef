#!/usr/bin/env bash
set -euo pipefail
LIBFFI=/cygdrive/d/Beef-master/Beef/BeefySysLib/third_party/libffi
TARGET=${TARGET:-x86_64-unknown-linux-musl}
HOST=${HOST:-$TARGET}
ZIG_TARGET=${ZIG_TARGET:-x86_64-linux-musl}
FFI_ARCH=${FFI_ARCH:-x86}
BUILD=$LIBFFI/build_$TARGET
PREFIX=$LIBFFI/$TARGET
TOOLS=/cygdrive/d/Beef-master/Beef/build_tools

rm -rf "$BUILD" "$PREFIX"
mkdir -p "$BUILD" "$PREFIX"
cd "$BUILD"

export CC="$TOOLS/zig-cc-cygwin.sh"
export CXX="$TOOLS/zig-cxx-cygwin.sh"
export AR="$TOOLS/zig-ar-cygwin.sh"
export RANLIB="$TOOLS/zig-ranlib-cygwin.sh"
export CFLAGS="--target=$ZIG_TARGET -fno-sanitize=all"
export CXXFLAGS="--target=$ZIG_TARGET -fno-sanitize=all"

"$LIBFFI/configure" --build=x86_64-pc-cygwin --host=$HOST --disable-docs --enable-static --disable-shared --prefix="$PREFIX"
make -j1
make install

mkdir -p "$PREFIX/src"
rm -rf "$BUILD/ffi_extract"
mkdir -p "$BUILD/ffi_extract"
cd "$BUILD/ffi_extract"
"$TOOLS/zig-ar-cygwin.sh" x "$PREFIX/lib/libffi.a"

mv prep_cif.o types.o raw_api.o java_raw_api.o closures.o tramp.o "$PREFIX/src/"
case "$FFI_ARCH" in
  x86)
    mkdir -p "$PREFIX/src/x86"
    mv ffi64.o unix64.o ffiw64.o win64.o "$PREFIX/src/x86/"
    ;;
  arm)
    mkdir -p "$PREFIX/src/arm"
    mv ffi.o sysv.o "$PREFIX/src/arm/"
    ;;
  aarch64)
    mkdir -p "$PREFIX/src/aarch64"
    mv ffi.o sysv.o "$PREFIX/src/aarch64/"
    ;;
  *)
    echo "Unknown FFI_ARCH: $FFI_ARCH" >&2
    exit 1
    ;;
esac
