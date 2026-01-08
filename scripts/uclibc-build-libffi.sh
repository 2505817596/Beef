#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBFFI="$ROOT/BeefySysLib/third_party/libffi"

TOOLCHAIN_ROOT=${TOOLCHAIN_ROOT:-/home/luckfox-pico/tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf}
TARGET_TRIPLE=${TARGET_TRIPLE:-arm-rockchip830-linux-uclibcgnueabihf}
SYSROOT_DEFAULT="$TOOLCHAIN_ROOT/arm-rockchip830-linux-uclibcgnueabihf/sysroot"
SYSROOT=${SYSROOT:-$SYSROOT_DEFAULT}
FFI_ARCH=${FFI_ARCH:-arm}
BUILD_DIR=${BUILD_DIR:-$LIBFFI/build_$TARGET_TRIPLE}
PREFIX=${PREFIX:-$LIBFFI/$TARGET_TRIPLE}
JOBS=${JOBS:-1}
ARM_FLAGS=${ARM_FLAGS:-"-march=armv7-a -mfpu=neon -mfloat-abi=hard"}

CC=${CC:-$TOOLCHAIN_ROOT/bin/${TARGET_TRIPLE}-gcc}
CXX=${CXX:-$TOOLCHAIN_ROOT/bin/${TARGET_TRIPLE}-g++}
AR=${AR:-$TOOLCHAIN_ROOT/bin/${TARGET_TRIPLE}-ar}
RANLIB=${RANLIB:-$TOOLCHAIN_ROOT/bin/${TARGET_TRIPLE}-ranlib}

if [[ ! -x "$CC" ]]; then
  echo "CC not found: $CC" >&2
  exit 1
fi
if [[ ! -d "$SYSROOT" ]]; then
  echo "Sysroot not found: $SYSROOT" >&2
  exit 1
fi

BUILD_TRIPLE=$("$LIBFFI/config.guess")

rm -rf "$BUILD_DIR" "$PREFIX"
mkdir -p "$BUILD_DIR" "$PREFIX"
cd "$BUILD_DIR"

export CC CXX AR RANLIB
export CFLAGS="--sysroot=$SYSROOT -fno-sanitize=all $ARM_FLAGS"
export CXXFLAGS="--sysroot=$SYSROOT -fno-sanitize=all $ARM_FLAGS"

"$LIBFFI/configure" --build="$BUILD_TRIPLE" --host="$TARGET_TRIPLE" --disable-docs --enable-static --disable-shared --prefix="$PREFIX"
make -j"$JOBS"
make install

mkdir -p "$PREFIX/src"
rm -rf "$BUILD_DIR/ffi_extract"
mkdir -p "$BUILD_DIR/ffi_extract"
cd "$BUILD_DIR/ffi_extract"
"$AR" x "$PREFIX/lib/libffi.a"

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
