# Zig 交叉编译到 Linux (musl) 的改动说明

本文记录在 Windows 上使用 Zig 进行 Linux(musl) 交叉编译所需的关键改动与使用方式，避免后续同步新源码时遗漏。

## 目标与前提

- 主机：Windows（无 WSL）
- 目标：`x86_64-unknown-linux-musl`（静态链接）
- 编译器：Zig（`zig.exe`）
- 仅需要运行时：`BeefRT` + `BeefySysLib`（不构建 IDE/LLVM）

## 环境变量

通过环境变量指向 Zig：

```
BEEF_ZIG=...\\zig.exe
```

或使用 `ZIG` 作为替代变量名。只要其中一个存在即可。

## 关键源码改动（需保留/移植）

### 1) Zig 作为 Linux 链接器（Windows 主机）

文件：`IDE/src/BuildContext.bf`

- 当目标平台为 Linux 且设置了 `BEEF_ZIG`/`ZIG` 时：
  - 禁用 WSL 路径转换
  - 使用 `zig c++` 作为链接入口（插入 `c++` 子命令）
  - 链接工作目录改为目标输出目录（保证 `./libBeefRT.a` 可被找到）
- 当目标 triple 包含 `musl` 时，运行库从 `IDE/dist_musl/` 复制
- 使用 Zig + musl 时对运行库 **强制覆盖拷贝**，避免旧的 Windows 版库因时间戳更新失败而残留

### 2) Zig 处理参数文件（避免 `zig @file` 报错）

文件：`IDE/src/IDEApp.bf`

- 当命令行过长进入参数文件模式时：
  - 如果执行的是 Zig 且命令以 `c++` / `cc` 开头，则改为
    `zig c++ @file` / `zig cc @file`
  - 只把“子命令后的真实参数”写入响应文件

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

### 5) 自举构建 BeefBuild 时避免 IDEHelper/Debugger64 依赖

文件：`BeefBuild/BeefSpace.toml`

- 新增 `Release.Win64` 配置并禁用：
  - `IDEHelper`
  - `Debugger64`
  - `BeefySysLib`
  
这样可以避免自举构建过程中因 DLL 被占用或缺失而失败。

### 6) arm32 指针大小识别

文件：`IDE/src/Workspace.bf`

- `GetPtrSizeByName` 增加 `arm-` 前缀识别，保证 `arm-linux-*` 目标被当成 32 位

## 构建流程（musl 运行库）

建议仅构建运行库（避免 IDEHelper/LLVM 依赖）：

```
cmake -G Ninja -S . -B build_musl_zig_rt ^
  -DBF_ONLY_RUNTIME=1 -DBF_DISABLE_FFI=1 ^
  -DCMAKE_SYSTEM_NAME=Linux ^
  -DCMAKE_C_COMPILER=zig.exe -DCMAKE_C_COMPILER_ARG1=cc ^
  -DCMAKE_CXX_COMPILER=zig.exe -DCMAKE_CXX_COMPILER_ARG1=c++ ^
  -DCMAKE_C_FLAGS="--target=x86_64-linux-musl" ^
  -DCMAKE_CXX_FLAGS="--target=x86_64-linux-musl" ^
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY ^
  -DCMAKE_BUILD_TYPE=Release

cmake --build build_musl_zig_rt --target BeefRT BeefySysLib -- -j1
```

输出库：

- `build_musl_zig_rt/Release/bin/libBeefRT.a`
- `build_musl_zig_rt/Release/bin/libBeefySysLib.a`

拷贝到（按架构区分目录）：

```
IDE/dist_musl_x64/
IDE/dist_musl_arm32/
```

如果目录不存在，会回退到 `IDE/dist_musl/`（兼容旧结构）。

校验（必须为 False）：

```
[Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes("IDE/dist_musl/libBeefRT.a")) -match "winmm\\.lib"
```

## ARM32 (armv7) 交叉编译补充

- Beef 平台名建议使用 `armv7-unknown-linux-musleabihf`（编译器按 `armv*` 识别 32 位）
- Zig 目标仍用 `arm-linux-musleabihf`
- CPU 参数注意下划线形式：`-mcpu=cortex_a7`
- 运行库构建示例（仅展示差异项）：

```
cmake -G Ninja -S . -B build_musl_arm32 ^
  -DBF_ONLY_RUNTIME=1 -DBF_DISABLE_FFI=1 ^
  -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm ^
  -DCMAKE_C_COMPILER=zig.exe -DCMAKE_C_COMPILER_ARG1=cc ^
  -DCMAKE_CXX_COMPILER=zig.exe -DCMAKE_CXX_COMPILER_ARG1=c++ ^
  -DCMAKE_C_FLAGS="--target=arm-linux-musleabihf -mcpu=cortex_a7 -mfpu=neon -mfloat-abi=hard" ^
  -DCMAKE_CXX_FLAGS="--target=arm-linux-musleabihf -mcpu=cortex_a7 -mfpu=neon -mfloat-abi=hard" ^
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY ^
  -DCMAKE_BUILD_TYPE=Release
```

- 运行库拷贝到：`IDE/dist_musl_arm32/`
- 若板子运行失败（如 `Exec format error` / `Illegal instruction`），尝试：
  - `--target=arm-linux-musleabi -mfloat-abi=softfp`
  - 去掉 `-mfpu=neon` 或改用更低的 `-mcpu`

## 项目链接配置（示例）

项目的 `OtherLinkFlags` 建议包含 `$(LinkFlags)`，否则会漏掉运行库：

```
[Configs.Release.x86_64-unknown-linux-musl]
OtherLinkFlags = "$(LinkFlags) --target=x86_64-linux-musl -static"

[Configs.Release.armv7-unknown-linux-musleabihf]
OtherLinkFlags = "$(LinkFlags) --target=arm-linux-musleabihf -static -mcpu=cortex_a7 -mfpu=neon -mfloat-abi=hard"
```

## 使用步骤（编译项目）

1) 设置环境变量 `BEEF_ZIG`
2) 使用更新后的 `BeefBuild.exe` 构建工程

## 脚本（可选，一键构建运行库）

脚本：`scripts/zig-build-musl-runtime.ps1`

```
.\scripts\zig-build-musl-runtime.ps1 -Arch x64 -Zig "D:\zig\zig.exe"
.\scripts\zig-build-musl-runtime.ps1 -Arch arm32 -Zig "D:\zig\zig.exe"
```

脚本会配置/构建运行库并拷贝到 `IDE/dist_musl_x64/` 或 `IDE/dist_musl_arm32/`。
如需 softfp 或降指令集，请修改脚本中 ARM32 的 `cpuFlags`。

## 常见问题

1) `zig` 报 `unknown command: @file`
   - 说明响应文件触发但未走 Zig 特殊处理
   - 需包含 `IDEApp.bf` 的改动并重建 BeefBuild

2) 链接报 `winmm.lib` 找不到
   - 说明 `libBeefRT.a` 仍是 Windows 版
   - 需按 musl 流程重新编译运行库并覆盖到 `IDE/dist_musl`

3) `./libBeefRT.a` 找不到
   - 链接工作目录需在目标输出目录（BuildContext 已修）

4) `Malformed structure values`（`__constEval` 崩溃）
   - 常见于 ARM32 平台名写成 `arm-linux-musleabihf`
   - 需改为 `armv7-unknown-linux-musleabihf`（Zig 目标仍用 `arm-linux-musleabihf`）

## 升级新源码时的动作清单

- 重新打补丁：
  - `IDE/src/BuildContext.bf`
  - `IDE/src/IDEApp.bf`
  - `IDE/src/Workspace.bf`
  - `BeefySysLib/platform/linux/LinuxCommon.cpp`
  - `BeefySysLib/platform/posix/PosixCommon.cpp`
  - `BeefySysLib/Common.cpp`
  - `BeefBuild/BeefSpace.toml`
- 重新用 Zig 构建 musl 运行库并覆盖到 `IDE/dist_musl`
- 重新编译 `BeefBuild.exe`（确保改动生效）
