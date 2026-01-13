# Zig 交叉编译到 Linux (musl) 的改动说明

本文记录在 Windows 上使用 Zig 进行 Linux(musl) 交叉编译所需的关键改动与使用方式，避免后续同步新源码时遗漏。

## 目标与前提

- 主机：Windows（无 WSL）
- 目标：`x86_64-unknown-linux-musl`（静态链接）
- 编译器：Zig（`zig.exe`）
- 仅需要运行时：`BeefRT` + `BeefySysLib`（不构建 IDE/LLVM）

## 环境变量

BeefBuild 通过 `BEEF_CXX`/`BEEF_CC` 指定外部编译器（用于链接）。建议指向
仓库自带的 Zig wrapper：

- Windows：`bin\zig-cxx.cmd` / `bin\zig-cc.cmd`
- Cygwin：`build_tools/zig-cxx-cygwin.sh` / `build_tools/zig-cc-cygwin.sh`

Wrapper 可选环境变量：

```
BEEF_ZIG_EXE=...\\zig.exe
BEEF_ZIG_TARGET=x86_64-linux-musl
```

## 关键源码改动（需保留/移植）

### 1) 外部链接器覆盖（Windows 主机）

文件：`IDE/src/BuildContext.bf`

当设置了 `BEEF_CXX`/`BEEF_CC` 时：

- 使用该可执行文件进行链接（适配 Zig 或外部交叉工具链）
- 链接工作目录改为目标输出目录（保证 `./libBeefRT.a` 可被找到）

运行库选择规则：

- 如果存在 `IDE/dist/rt/<TargetTriple>`，优先从该目录拷贝
- 否则从 `IDE/dist` 根目录拷贝
- 可用 `BEEF_RT_DIR` 手动覆盖运行库目录

### 2) Zig 响应文件

无需修改 `IDEApp.bf`。使用 wrapper（`zig-cc/cxx`）即可避免 `zig @file`
缺少子命令的问题。

### 3) musl 下的头文件与 64 位 API 兼容

文件：`BeefySysLib/platform/linux/LinuxCommon.cpp`

- 仅在存在 `<execinfo.h>` 时定义 `BFP_HAS_EXECINFO`
  - 兼容 musl 环境缺失 `execinfo.h`

文件：`BeefySysLib/platform/posix/PosixCommon.cpp`

- 当 Linux 下缺少 `execinfo.h` 时，为 `lseek64` / `ftruncate64` 增加兼容宏映射

### 4) Windows 专用 pragma 防止污染 Linux 静态库

文件：`BeefySysLib/Common.cpp`

- 仅在 Windows 下启用：
  - `#pragma comment(lib, "winmm.lib")`
- `#pragma warning` 仅在 MSVC 下生效

### 5) arm32 指针大小识别

文件：`IDE/src/Workspace.bf`

- `GetPtrSizeByName` 增加 `arm-` 前缀识别，保证 `arm-linux-*` 目标被当成 32 位

## 构建流程（musl 运行库）

建议仅构建运行库（避免 IDEHelper/LLVM 依赖）：

```
dotnet run .\scripts\zig-build-musl-runtime.cs -- -Arch x64 -Zig "D:\zig\zig.exe"
```

输出库：

- `IDE/dist/rt/x86_64-unknown-linux-musl/libBeefRT.a`
- `IDE/dist/rt/x86_64-unknown-linux-musl/libBeefySysLib.a`

手动构建（可选）：

```
set BEEF_ZIG_EXE=D:\zig\zig.exe
cmake -G Ninja -S . -B build_musl_zig_rt ^
  -DBF_ONLY_RUNTIME=1 -DBF_DISABLE_FFI=1 ^
  -DCMAKE_SYSTEM_NAME=Linux ^
  -DCMAKE_C_COMPILER=bin\zig-cc.cmd ^
  -DCMAKE_CXX_COMPILER=bin\zig-cxx.cmd ^
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY ^
  -DCMAKE_BUILD_TYPE=Release

cmake --build build_musl_zig_rt --target BeefRT BeefySysLib -- -j1
```

校验（必须为 False）：

```
[Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes("IDE/dist/rt/x86_64-unknown-linux-musl/libBeefRT.a")) -match "winmm\\.lib"
```

## ARM32 (armv7) 交叉编译补充

- Beef 平台名建议使用 `armv7-unknown-linux-musleabihf`（编译器按 `armv*` 识别 32 位）
- Zig 目标仍用 `arm-linux-musleabihf`
- CPU 参数注意下划线形式：`-mcpu=cortex_a7`
- 运行库构建示例（仅展示差异项）：

```
dotnet run .\scripts\zig-build-musl-runtime.cs -- -Arch arm32 -Zig "D:\zig\zig.exe"
```

- 运行库拷贝到：`IDE/dist/rt/armv7-unknown-linux-musleabihf/`
- 若板子运行失败（如 `Exec format error` / `Illegal instruction`），尝试：
  - `--target=arm-linux-musleabi -mfloat-abi=softfp`
  - 去掉 `-mfpu=neon` 或改用更低的 `-mcpu`

## 项目链接配置（示例）

项目的 `OtherLinkFlags` 建议包含 `$(LinkFlags)`，否则会漏掉运行库：

```
[Configs.Release.x86_64-unknown-linux-musl]
OtherLinkFlags = "$(LinkFlags) -static"

[Configs.Release.armv7-unknown-linux-musleabihf]
OtherLinkFlags = "$(LinkFlags) -static -mcpu=cortex_a7 -mfpu=neon -mfloat-abi=hard"
```

如果没有使用 wrapper（直接调用 `zig.exe`），请额外加 `--target=...`。

## 使用步骤（编译项目）

1) 设置 `BEEF_CXX`/`BEEF_CC` 指向 wrapper
2) 使用更新后的 `BeefBuild.exe` 构建工程

## 脚本（可选，一键构建运行库）

脚本：`scripts/zig-build-musl-runtime.cs`

```
dotnet run .\scripts\zig-build-musl-runtime.cs -- -Arch x64 -Zig "D:\zig\zig.exe"
dotnet run .\scripts\zig-build-musl-runtime.cs -- -Arch arm32 -Zig "D:\zig\zig.exe"
```

脚本会配置/构建运行库并拷贝到 `IDE/dist/rt/<TargetTriple>/`。
如需 softfp 或降指令集，请修改脚本中 ARM32 的 `cpuFlags`。

## 常见问题

1) `zig` 报 `unknown command: @file`
   - 说明直接调用了 `zig.exe`，缺少 `cc/c++` 子命令
   - 改为使用 wrapper（`bin\zig-cc.cmd` / `bin\zig-cxx.cmd`）

2) 链接报 `winmm.lib` 找不到
   - 说明 `libBeefRT.a` 仍是 Windows 版
   - 需按 musl 流程重新编译运行库并覆盖到 `IDE/dist/rt/<TargetTriple>`

3) `./libBeefRT.a` 找不到
   - 检查运行库是否在 `IDE/dist/rt/<TargetTriple>`（或 `BEEF_RT_DIR`）

4) `Malformed structure values`（`__constEval` 崩溃）
   - 常见于 ARM32 平台名写成 `arm-linux-musleabihf`
   - 需改为 `armv7-unknown-linux-musleabihf`（Zig 目标仍用 `arm-linux-musleabihf`）

## 升级新源码时的动作清单

- 重新打补丁：
  - `IDE/src/BuildContext.bf`
  - `IDE/src/Workspace.bf`
  - `BeefySysLib/platform/linux/LinuxCommon.cpp`
  - `BeefySysLib/platform/posix/PosixCommon.cpp`
  - `BeefySysLib/Common.cpp`
  - `BeefRT/CMakeLists.txt`
  - `BeefLibs/corlib/src/FFI/Function.bf`
  - `scripts/zig-build-musl-runtime.cs`
  - `bin/zig-cc.cmd`
  - `bin/zig-cxx.cmd`
  - `build_tools/zig-cc-cygwin.sh`
  - `build_tools/zig-cxx-cygwin.sh`
- 重新用 Zig 构建 musl 运行库并覆盖到 `IDE/dist/rt/<TargetTriple>`
- 重新编译 `BeefBuild.exe`（确保改动生效）
