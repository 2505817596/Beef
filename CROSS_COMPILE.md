# Cross Compile Notes (zig + armv7 uClibc)

## Purpose
Record the source changes and commands needed to reproduce cross compilation.

## Source changes (reapply after new source drops)
1) IDE/src/BuildContext.bf
   - Add env override for compiler path:
     - read BEEF_CXX/BEEF_CC
     - if set, use that executable for linking
   - This lets BeefBuild point to zig or an external cross toolchain.
2) BeefySysLib/platform/linux/LinuxCommon.cpp
   - Only define BFP_HAS_EXECINFO when <execinfo.h> exists or glibc.
   - Only define BFP_HAS_DLINFO on glibc (uClibc lacks dlinfo/RTLD_DI_LINKMAP).
3) BeefySysLib/platform/posix/PosixCommon.cpp
   - uClibc: map lseek64/ftruncate64 -> lseek/ftruncate.
   - uClibc: disable _Unwind backtrace; FancyBacktrace returns false.
4) BeefBuild/BeefProj.toml (host build fix)
   - Linux64 OtherLinkFlags include LLVM 19:
     - -L/usr/lib/llvm-19/lib -lLLVM-19 -Wl,-rpath -Wl,$ORIGIN
   - Ensure a space before -Wl.
5) BeefRT/CMakeLists.txt (FFI cross support)
   - Add BF_FFI_TARGET_DIR / BF_FFI_ARCH cache variables.
   - Use BF_FFI_TARGET_DIR for libffi include path and object list.
   - Add arm32 libffi object list (src/arm/ffi.o, src/arm/sysv.o).
6) BeefLibs/corlib/src/FFI/Function.bf (ARM32 FFI)
   - Add ARM VFP fields to FFICIF to match libffi's ffi_cif layout.
   - Default ABI on ARM to VFP for hard-float (so integer returns work).

## zig cross compile (musl)
Use wrapper scripts so BeefBuild can call zig with the required subcommand.

zig-cxx:
```bash
#!/bin/sh
exec /path/to/zig c++ "$@"
```

zig-cc:
```bash
#!/bin/sh
exec /path/to/zig cc "$@"
```

Build runtime libs with CMake using the wrappers and target flags for your
platform (example: x86_64-linux-musl). Then build the project:
```bash
export BEEF_CXX=/path/to/zig-cxx
export BEEF_CC=/path/to/zig-cc
/path/to/BeefBuild -platform=x86_64-unknown-linux-musl -config=Release
```

## armv7 uClibc cross compile

### Toolchain
```bash
TC=/home/luckfox-pico/tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf
CC=$TC/bin/arm-rockchip830-linux-uclibcgnueabihf-gcc
CXX=$TC/bin/arm-rockchip830-linux-uclibcgnueabihf-g++
SYSROOT=$($CC -print-sysroot)
```

### Build runtime libs
If you want FFI disabled, add -DBF_DISABLE_FFI=1. For FFI-enabled builds,
omit that define and use BF_FFI_* as shown in the FFI section below.
```bash
cmake -G Ninja -S /home/Beef-master -B /home/Beef-master/build_uclibc_arm32 \
  -DBF_ONLY_RUNTIME=1 \
  -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm \
  -DCMAKE_C_COMPILER=$CC -DCMAKE_CXX_COMPILER=$CXX \
  -DCMAKE_SYSROOT=$SYSROOT \
  -DCMAKE_C_FLAGS="--sysroot=$SYSROOT -mcpu=cortex-a7 -mfpu=neon -mfloat-abi=hard" \
  -DCMAKE_CXX_FLAGS="--sysroot=$SYSROOT -mcpu=cortex-a7 -mfpu=neon -mfloat-abi=hard" \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_BUILD_TYPE=Release
cmake --build /home/Beef-master/build_uclibc_arm32 -- -j1
```

### Point IDE/dist at uClibc libs
```bash
ln -sf /home/Beef-master/build_uclibc_arm32/Release/bin/libBeefRT.a /home/Beef-master/IDE/dist/libBeefRT.a
ln -sf /home/Beef-master/build_uclibc_arm32/Release/bin/libBeefySysLib.a /home/Beef-master/IDE/dist/libBeefySysLib.a
```

When rebuilding host BeefBuild, revert these to:
```bash
ln -sf /home/Beef-master/jbuild/Release/bin/libBeefRT.a /home/Beef-master/IDE/dist/libBeefRT.a
ln -sf /home/Beef-master/jbuild/Release/bin/libBeefySysLib.a /home/Beef-master/IDE/dist/libBeefySysLib.a
```

### Project settings
Workspace file (example /home/beefdemo/BeefSpace.toml):
```toml
[Configs.Release.armv7-unknown-linux-uclibcgnueabihf]
TargetTriple = "armv7-unknown-linux-gnueabihf"
TargetCPU = "cortex-a7"
```

Project file (example /home/beefdemo/BeefProj.toml):
```toml
[Configs.Release.armv7-unknown-linux-uclibcgnueabihf]
CLibType = "Dynamic"
```

Dynamic is required because the uClibc toolchain lacks unwind symbols used by
static libgcc.

### Build project
```bash
BEEF_CC=$CC BEEF_CXX=$CXX /home/Beef-master/IDE/dist/BeefBuild \
  -platform=armv7-unknown-linux-uclibcgnueabihf -config=Release
```

### Enable FFI (uClibc armv7)
Build libffi into a target-named subdir, then rebuild BeefRT with FFI enabled.

```bash
TC=/home/luckfox-pico/tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf
CC=$TC/bin/arm-rockchip830-linux-uclibcgnueabihf-gcc
CXX=$TC/bin/arm-rockchip830-linux-uclibcgnueabihf-g++
AR=$TC/bin/arm-rockchip830-linux-uclibcgnueabihf-ar
RANLIB=$TC/bin/arm-rockchip830-linux-uclibcgnueabihf-ranlib
SYSROOT=$($CC -print-sysroot)

cd /home/Beef-master/BeefySysLib/third_party/libffi
rm -rf arm-unknown-linux-gnueabihf
mkdir arm-unknown-linux-gnueabihf
cd arm-unknown-linux-gnueabihf
../configure --host=arm-rockchip830-linux-uclibcgnueabihf --disable-docs --enable-static --disable-shared \
  CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB" \
  CFLAGS="--sysroot=$SYSROOT -mcpu=cortex-a7 -mfpu=neon -mfloat-abi=hard" \
  CXXFLAGS="--sysroot=$SYSROOT -mcpu=cortex-a7 -mfpu=neon -mfloat-abi=hard"
make -j1

cmake -G Ninja -S /home/Beef-master -B /home/Beef-master/build_uclibc_arm32 \
  -DBF_ONLY_RUNTIME=1 \
  -DBF_FFI_TARGET_DIR=arm-unknown-linux-gnueabihf -DBF_FFI_ARCH=arm \
  -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm \
  -DCMAKE_C_COMPILER=$CC -DCMAKE_CXX_COMPILER=$CXX \
  -DCMAKE_SYSROOT=$SYSROOT \
  -DCMAKE_C_FLAGS="--sysroot=$SYSROOT -mcpu=cortex-a7 -mfpu=neon -mfloat-abi=hard" \
  -DCMAKE_CXX_FLAGS="--sysroot=$SYSROOT -mcpu=cortex-a7 -mfpu=neon -mfloat-abi=hard" \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_BUILD_TYPE=Release
cmake --build /home/Beef-master/build_uclibc_arm32 -- -j1
```

### Output
```bash
/home/beefdemo/build/Release_armv7-unknown-linux-uclibcgnueabihf/beefdemo/beefdemo
```

### On target device
Copy the binary and run it. If it fails to start, run ldd on the device and
install missing libs (libgcc_s, libstdc++, etc).

## Common errors and fixes
- "relocations in generic ELF (EM: 40)" or "file in wrong format"
  - Host linker was used. Export BEEF_CC/BEEF_CXX to the cross toolchain.
  - Ensure the command is on one line so -config=Release is not dropped.
  - Clean the build dir and rebuild.
- "uses VFP register arguments ... does not"
  - Hard/soft float mismatch. Set TargetTriple to armv7-unknown-linux-gnueabihf
    and TargetCPU to cortex-a7, then clean rebuild.
- "undefined reference to _Unwind_GetIP"
  - uClibc toolchain lacks unwind for static libgcc. Use CLibType=Dynamic and
    keep unwind backtrace disabled for uClibc; rebuild runtime libs.
- "execinfo.h not found" or "backtrace/backtrace_symbols undefined"
  - Disable BFP_HAS_EXECINFO on uClibc; only enable when execinfo exists.
- "RTLD_DI_LINKMAP/dlinfo not declared"
  - Disable BFP_HAS_DLINFO on uClibc; only enable on glibc.
- "zig: unknown command: @/tmp/xxx"
  - Zig needs a subcommand. Use zig-cc/zig-cxx wrapper scripts and set
    BEEF_CC/BEEF_CXX to those wrappers.
- "libBeefRT.a: file not found"
  - Ensure IDE/dist has symlinks to the correct runtime libs and run BeefBuild
    from a project directory.
- "FFI pid=0" or "FFI segfault on ARM"
  - FFICIF layout was missing ARM VFP fields and ABI default was SysV.
  - Update corlib FFI layout (Function.bf) and rebuild runtime + project.
