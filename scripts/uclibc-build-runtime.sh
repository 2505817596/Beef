#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TOOLCHAIN_ROOT=${TOOLCHAIN_ROOT:-/home/luckfox-pico/tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf}
TARGET_TRIPLE=${TARGET_TRIPLE:-arm-rockchip830-linux-uclibcgnueabihf}
SYSROOT_DEFAULT="$TOOLCHAIN_ROOT/arm-rockchip830-linux-uclibcgnueabihf/sysroot"
SYSROOT=${SYSROOT:-$SYSROOT_DEFAULT}
BUILD_DIR=${BUILD_DIR:-$ROOT/build_uclibc_arm}
OUT_DIR=${OUT_DIR:-$ROOT/IDE/dist/rt/$TARGET_TRIPLE}
FFI_TARGET_DIR=${FFI_TARGET_DIR:-$TARGET_TRIPLE}
FFI_ARCH=${FFI_ARCH:-arm}
ENABLE_FFI=${ENABLE_FFI:-1}
JOBS=${JOBS:-1}
ARM_FLAGS=${ARM_FLAGS:-"-march=armv7-a -mfpu=neon -mfloat-abi=hard"}

CC=${CC:-$TOOLCHAIN_ROOT/bin/${TARGET_TRIPLE}-gcc}
CXX=${CXX:-$TOOLCHAIN_ROOT/bin/${TARGET_TRIPLE}-g++}

if [[ ! -x "$CC" ]]; then
  echo "CC not found: $CC" >&2
  exit 1
fi
if [[ ! -d "$SYSROOT" ]]; then
  echo "Sysroot not found: $SYSROOT" >&2
  exit 1
fi

CFLAGS="--sysroot=$SYSROOT -fno-sanitize=all $ARM_FLAGS"
CXXFLAGS="--sysroot=$SYSROOT -fno-sanitize=all $ARM_FLAGS"

GEN_ARGS=()
if command -v ninja >/dev/null 2>&1; then
  GEN_ARGS=(-G Ninja)
fi

cmake_args=(
  "${GEN_ARGS[@]}"
  -S "$ROOT"
  -B "$BUILD_DIR"
  -DBF_ONLY_RUNTIME=1
  -DCMAKE_SYSTEM_NAME=Linux
  -DCMAKE_SYSTEM_PROCESSOR=arm
  -DCMAKE_C_COMPILER="$CC"
  -DCMAKE_CXX_COMPILER="$CXX"
  -DCMAKE_SYSROOT="$SYSROOT"
  -DCMAKE_FIND_ROOT_PATH="$SYSROOT"
  -DCMAKE_C_FLAGS="$CFLAGS"
  -DCMAKE_CXX_FLAGS="$CXXFLAGS"
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
  -DCMAKE_BUILD_TYPE=Release
)

if [[ "$ENABLE_FFI" != "0" ]]; then
  cmake_args+=(-UBF_DISABLE_FFI -DBF_FFI_TARGET_DIR="$FFI_TARGET_DIR" -DBF_FFI_ARCH="$FFI_ARCH")
else
  cmake_args+=(-DBF_DISABLE_FFI=1)
fi

cmake "${cmake_args[@]}"
cmake --build "$BUILD_DIR" --config Release -- -j "$JOBS"

BIN_DIR="$BUILD_DIR/Release/bin"
if [[ ! -d "$BIN_DIR" ]]; then
  echo "Build output not found: $BIN_DIR" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
cp -f "$BIN_DIR/libBeefRT.a" "$OUT_DIR/libBeefRT.a"
cp -f "$BIN_DIR/libBeefySysLib.a" "$OUT_DIR/libBeefySysLib.a"

echo "Done. Runtime libs in: $OUT_DIR"
