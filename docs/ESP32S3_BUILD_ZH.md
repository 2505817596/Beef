# ESP32-S3 编译指南（esp32s3-beef 分支）

本指南用于在全新电脑上从零搭建环境，编译 Beef 的 ESP32-S3 静态库并接入 ESP-IDF 工程。

范围：
- 不启用 FFI（纯静态链接）。
- Xtensa 目标使用 emulated TLS（该分支已启用）。
- 主机端工具使用 MSVC；Xtensa 后端使用 esp-llvm。

## 1) 准备环境（Windows）

- Visual Studio 2022（MSVC 工具链）
- ESP-IDF v5.5.x（包含 Xtensa GCC、CMake、Ninja）
- esp-llvm（带 Xtensa 目标的构建，例如 `C:\esp-llvm-msvc`）
- Git

假设仓库路径为 `D:\Beef-master\Beef`，分支为 `esp32s3-beef`。

## 2) 构建主机端工具（MSVC + 内置 LLVM）

```bat
cd /d D:\Beef-master\Beef
bin\build.bat
```

这一步生成 BeefBuild/IDE/Debugger，使用 Beef 自带 LLVM。

## 3) 用 esp-llvm 重建 IDEHelper（启用 Xtensa 后端）

只有 IDEHelper 需要链接 esp-llvm；其它工具仍用内置 LLVM。

```bat
cd /d D:\Beef-master\Beef
set BEEF_LLVM_EXTRA_INCLUDE=C:\esp-llvm-msvc\build\include
set BEEF_LLVM_EXTRA_LIBDIR=C:\esp-llvm-msvc\build\lib
set BEEF_LLVM_EXTRA_LIBS=LLVMXtensaInfo.lib;LLVMXtensaDesc.lib;LLVMXtensaCodeGen.lib;LLVMXtensaDisassembler.lib;LLVMXtensaAsmParser.lib
bin\msbuild.bat IDEHelper\IDEHelper.vcxproj /p:Configuration=Release /p:Platform=x64 /p:SolutionDir=%cd%\
```

结果：`IDE\dist\IDEHelper64.dll` 被替换为支持 Xtensa 的版本。

## 4) 构建 ESP32-S3 运行库（BeefRT/BeefySysLib）

先进入 ESP-IDF 环境，确保 Xtensa GCC 在 PATH 里：

```bat
cd /d D:\fairy\esp32demo\esp-idf
export.bat
where xtensa-esp32s3-elf-gcc
where xtensa-esp32s3-elf-g++
where xtensa-esp32s3-elf-ar
```

然后用 CMake 交叉编译运行库（替换为你的实际路径）：

```bat
cd /d D:\Beef-master\Beef
set XTENSA_GCC=C:\path\xtensa-esp32s3-elf-gcc.exe
set XTENSA_GXX=C:\path\xtensa-esp32s3-elf-g++.exe
set XTENSA_AR=C:\path\xtensa-esp32s3-elf-ar.exe
set XTENSA_SYSROOT=C:\path\xtensa-esp-elf

cmake -G Ninja -S . -B build_esp32s3 ^
  -DBF_ONLY_RUNTIME=1 ^
  -DCMAKE_SYSTEM_NAME=Generic -DCMAKE_SYSTEM_PROCESSOR=xtensa ^
  -DCMAKE_C_COMPILER=%XTENSA_GCC% -DCMAKE_CXX_COMPILER=%XTENSA_GXX% ^
  -DCMAKE_AR=%XTENSA_AR% ^
  -DCMAKE_C_FLAGS="--sysroot=%XTENSA_SYSROOT% -mlongcalls" ^
  -DCMAKE_CXX_FLAGS="--sysroot=%XTENSA_SYSROOT% -mlongcalls" ^
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY ^
  -DCMAKE_BUILD_TYPE=Release

cmake --build build_esp32s3 --config Release
```

拷贝运行库到 Beef dist：

```bat
cd /d D:\Beef-master\Beef
mkdir IDE\dist\rt\xtensa-esp32s3-elf
copy build_esp32s3\Release\bin\libBeefRT.a IDE\dist\rt\xtensa-esp32s3-elf\
copy build_esp32s3\Release\bin\libBeefySysLib.a IDE\dist\rt\xtensa-esp32s3-elf\
```

## 5) 构建 Beef 工程的 ESP32 静态库

在 `BeefSpace.toml` 里加入 ESP32 配置：

```toml
ExtraPlatforms = ["ESP32"]

[Configs.Release.ESP32]
Toolset = "GNU"
TargetTriple = "xtensa-esp32s3-elf"
TargetCPU = "esp32s3"
RelocType = "Static"
PICLevel = "Not"
AllocType = "CRT"
```

编译：

```bat
cd /d D:\Beef-master\Beef
set BEEF_RT_DIR=D:\Beef-master\Beef\IDE\dist\rt\xtensa-esp32s3-elf
set BEEF_AR=C:\esp-llvm-msvc\build\bin\llvm-ar.exe
IDE\dist\BeefBuild.exe -workspace="D:\fairy\beefesp32demo" -config=Release -platform=ESP32
```

产物：
- `beefesp32demo.a`
- `corlib.a`

## 6) 接入 ESP-IDF（components/beef）

在 ESP-IDF 工程下创建 `components/beef`，包含：
- `CMakeLists.txt`
- `beef_component.c`
- `beef_stub.c`
- `lib/`（放四个静态库）

把库拷贝到组件目录：

```bat
mkdir components\beef\lib
copy D:\fairy\beefesp32demo\build\Release_ESP32\beefesp32demo\beefesp32demo.a components\beef\lib\
copy D:\fairy\beefesp32demo\build\Release_ESP32\corlib\corlib.a components\beef\lib\
copy D:\Beef-master\Beef\IDE\dist\rt\xtensa-esp32s3-elf\libBeefRT.a components\beef\lib\
copy D:\Beef-master\Beef\IDE\dist\rt\xtensa-esp32s3-elf\libBeefySysLib.a components\beef\lib\
```

`main/CMakeLists.txt` 加入 `beef` 依赖：

```cmake
idf_component_register(SRCS "hello_world_main.c"
                       PRIV_REQUIRES spi_flash beef)
```

`app_main` 中最小初始化示例：

```c
void BfpSystem_Init(int version, int flags);
void BfpSystem_SetCommandLine(int argc, char** argv);
void BfRuntime_Startup(void);
int BeefEntryMain(void);

void app_main(void)
{
    static char beef_arg0[] = "beef";
    static char* beef_argv[] = { beef_arg0, NULL };
    BfpSystem_Init(2, 0);
    BfpSystem_SetCommandLine(1, beef_argv);
    BfRuntime_Startup();
    BeefEntryMain(); // Beef 内部自行决定是否常驻循环
}
```

## 7) 编译 + 烧录

```bat
idf.py build
idf.py -p COM4 flash
idf.py -p COM4 monitor
```

## 8) 一键脚本（dotnet 单文件）

需要 .NET 10（支持 `dotnet run <file.cs>`）。在仓库根目录执行：

```bat
dotnet run scripts\esp32_build.cs -- ^
  -WorkspacePath D:\fairy\beefesp32demo ^
  -IdfProjectPath D:\fairy\esp32demo\hello_world ^
  -IdfRoot D:\fairy\esp32demo\esp-idf ^
  -EspLlvmRoot D:\fairy\esp-llvm-msvc ^
  -CopyRuntime -Flash -Monitor -Port COM4 -Baud 921600
```

说明：
- 脚本会从当前目录向上自动定位 Beef 根目录；不在根目录执行时，也可显式传 `-BeefRoot`。
- `-Baud 0` 可禁用脚本中的波特率覆盖，使用 IDF 默认值。

## 备注

- IDEHelper 必须是“链接了 esp-llvm Xtensa 库”的版本，否则无法生成 Xtensa 目标。
- ESP32 目标的 TLS 使用 emulated TLS，避免 `@TPOFF` 链接错误。
- 必须在调用任何 Beef 入口（如 `BeefApp_Init`）之前调用 `BfRuntime_Startup`，否则线程/回调未初始化会崩溃。
- `chdir/chmod/getcwd` 的 linker warning 属于裸机环境下的已知行为。
