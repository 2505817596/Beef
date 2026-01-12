# ESP32-S3 build notes (esp32s3-beef branch)

This document describes a repeatable setup for building Beef static libraries
for ESP32-S3 and integrating them into an ESP-IDF app.

Scope:
- No FFI (static link only).
- Xtensa target uses emulated TLS (already in this branch).
- Host tools use MSVC; Xtensa backend uses esp-llvm.

## Prerequisites (Windows)

- Visual Studio 2022 (MSVC toolchain)
- ESP-IDF v5.5.x (includes Xtensa GCC toolchain, CMake, Ninja)
- esp-llvm build with Xtensa target (example root: `C:\esp-llvm-msvc`)
- Git

Assume this repo is cloned to `D:\Beef-master\Beef` and the branch is
`esp32s3-beef`.

## 1) Build host tools (MSVC + Beef internal LLVM)

```bat
cd /d D:\Beef-master\Beef
bin\build.bat
```

This builds BeefBuild/IDE/Debugger with the internal LLVM.

## 2) Rebuild IDEHelper with Xtensa LLVM (esp-llvm)

IDEHelper must link Xtensa LLVM libs so BeefBuild can emit Xtensa objects.
Only IDEHelper needs esp-llvm; the rest stays on internal LLVM.

```bat
cd /d D:\Beef-master\Beef
set BEEF_LLVM_EXTRA_INCLUDE=C:\esp-llvm-msvc\build\include
set BEEF_LLVM_EXTRA_LIBDIR=C:\esp-llvm-msvc\build\lib
set BEEF_LLVM_EXTRA_LIBS=LLVMXtensaInfo.lib;LLVMXtensaDesc.lib;LLVMXtensaCodeGen.lib;LLVMXtensaDisassembler.lib;LLVMXtensaAsmParser.lib
bin\msbuild.bat IDEHelper\IDEHelper.vcxproj /p:Configuration=Release /p:Platform=x64 /p:SolutionDir=%cd%\
```

Result: `IDE\dist\IDEHelper64.dll` is replaced with an Xtensa-capable build.

## 3) Build ESP32-S3 runtime libs (BeefRT/BeefySysLib)

Start an ESP-IDF shell so the Xtensa GCC toolchain is on PATH:

```bat
cd /d D:\fairy\esp32demo\esp-idf
export.bat
```

Find toolchain paths:

```bat
where xtensa-esp32s3-elf-gcc
where xtensa-esp32s3-elf-g++
where xtensa-esp32s3-elf-ar
```

Set these paths in the commands below:

```bat
cd /d D:\Beef-master\Beef
set XTENSA_GCC=C:\path\to\xtensa-esp32s3-elf-gcc.exe
set XTENSA_GXX=C:\path\to\xtensa-esp32s3-elf-g++.exe
set XTENSA_AR=C:\path\to\xtensa-esp32s3-elf-ar.exe
set XTENSA_SYSROOT=C:\path\to\xtensa-esp-elf

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

Copy runtime libs into Beef dist:

```bat
cd /d D:\Beef-master\Beef
mkdir IDE\dist\rt\xtensa-esp32s3-elf
copy build_esp32s3\Release\bin\libBeefRT.a IDE\dist\rt\xtensa-esp32s3-elf\
copy build_esp32s3\Release\bin\libBeefySysLib.a IDE\dist\rt\xtensa-esp32s3-elf\
```

## 4) Build Beef libs for ESP32-S3

Example workspace path: `D:\fairy\beefesp32demo`.

In `BeefSpace.toml`, ensure:

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

Build with BeefBuild (use esp-llvm `llvm-ar`):

```bat
cd /d D:\Beef-master\Beef
set BEEF_RT_DIR=D:\Beef-master\Beef\IDE\dist\rt\xtensa-esp32s3-elf
set BEEF_AR=C:\esp-llvm-msvc\build\bin\llvm-ar.exe
IDE\dist\BeefBuild.exe -workspace="D:\fairy\beefesp32demo" -config=Release -platform=ESP32
```

Outputs:
- `beefesp32demo.a`
- `corlib.a`

## 5) ESP-IDF integration (components/beef)

Create `components/beef` in your ESP-IDF project and add:

`components/beef/CMakeLists.txt`:
```cmake
cmake_minimum_required(VERSION 3.5)

idf_component_register(SRCS "beef_component.c" "beef_stub.c"
                      INCLUDE_DIRS "include"
                      PRIV_REQUIRES esp_netif
                      WHOLE_ARCHIVE)

set(BEEF_LIB_DIR "${CMAKE_CURRENT_LIST_DIR}/lib")
set(BEEF_LIBS "")

foreach(lib IN ITEMS libBeefRT.a libBeefySysLib.a)
  if (EXISTS "${BEEF_LIB_DIR}/${lib}")
    list(APPEND BEEF_LIBS "${BEEF_LIB_DIR}/${lib}")
  endif()
endforeach()

file(GLOB APP_LIBS "${BEEF_LIB_DIR}/*.a")
list(REMOVE_ITEM APP_LIBS
  "${BEEF_LIB_DIR}/libBeefRT.a"
  "${BEEF_LIB_DIR}/libBeefySysLib.a"
  "${BEEF_LIB_DIR}/corlib.a"
)
list(APPEND BEEF_LIBS ${APP_LIBS})
if (EXISTS "${BEEF_LIB_DIR}/corlib.a")
  list(APPEND BEEF_LIBS "${BEEF_LIB_DIR}/corlib.a")
endif()

if (BEEF_LIBS)
  target_link_libraries(${COMPONENT_LIB} INTERFACE ${BEEF_LIBS})
endif()
```

`components/beef/beef_component.c`:
```c
#include "beef_app.h"
void beef_component_marker(void) {}
```

`components/beef/beef_stub.c`:
```c
#include <errno.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <sys/types.h>
#include <unistd.h>

#include "sdkconfig.h"
#include "esp_err.h"
#include "esp_netif.h"

int gethostname(char* name, size_t len)
{
    const char* hostname = NULL;
    if ((name == NULL) || (len == 0)) { errno = EINVAL; return -1; }

    esp_netif_t* netif = NULL;
    const char* netif_hostname = NULL;
    netif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
    if (netif == NULL) netif = esp_netif_get_handle_from_ifkey("WIFI_AP_DEF");
    if (netif == NULL) netif = esp_netif_get_handle_from_ifkey("ETH_DEF");
    if (netif != NULL) {
        if (esp_netif_get_hostname(netif, &netif_hostname) == ESP_OK) {
            if ((netif_hostname != NULL) && (netif_hostname[0] != 0))
                hostname = netif_hostname;
        }
    }
#ifdef CONFIG_LWIP_LOCAL_HOSTNAME
    if ((hostname == NULL) || (hostname[0] == 0))
        hostname = CONFIG_LWIP_LOCAL_HOSTNAME;
#endif
    if ((hostname == NULL) || (hostname[0] == 0))
        hostname = "esp32";

    size_t copy_len = strnlen(hostname, len - 1);
    memcpy(name, hostname, copy_len);
    name[copy_len] = 0;
    return 0;
}

int sigaction(int signum, const struct sigaction* act, struct sigaction* oldact)
{
    (void)signum; (void)act; (void)oldact;
    errno = ENOSYS;
    return -1;
}

uid_t geteuid(void) { return 0; }
gid_t getegid(void) { return 0; }

int getgroups(int size, gid_t* list)
{
    if (size < 0) { errno = EINVAL; return -1; }
    if ((size > 0) && (list != NULL)) list[0] = 0;
    return 0;
}

ssize_t readlink(const char* path, char* buf, size_t bufsiz)
{
    (void)path; (void)buf; (void)bufsiz;
    errno = ENOSYS;
    return -1;
}

long sysconf(int name)
{
    (void)name;
    errno = ENOSYS;
    return -1;
}

void __wrap__Unwind_Resume(void* ex) { (void)ex; abort(); }
int __wrap__Unwind_Backtrace(void* trace_fn, void* trace_arg) { (void)trace_fn; (void)trace_arg; return 0; }
uintptr_t __wrap__Unwind_GetIP(void* ctx) { (void)ctx; return 0; }
void __wrap__Unwind_DeleteException(void* ex) { (void)ex; }
int __wrap___gxx_personality_v0() { return 0; }
void* __wrap___cxa_allocate_exception(size_t thrown_size) { (void)thrown_size; abort(); return NULL; }
void __wrap___cxa_throw(void* thrown_exception, void* tinfo, void* dest)
{ (void)thrown_exception; (void)tinfo; (void)dest; abort(); }
```

Copy libs into the component:

```bat
mkdir components\beef\lib
copy D:\fairy\beefesp32demo\build\Release_ESP32\beefesp32demo\beefesp32demo.a components\beef\lib\
copy D:\fairy\beefesp32demo\build\Release_ESP32\corlib\corlib.a components\beef\lib\
copy D:\Beef-master\Beef\IDE\dist\rt\xtensa-esp32s3-elf\libBeefRT.a components\beef\lib\
copy D:\Beef-master\Beef\IDE\dist\rt\xtensa-esp32s3-elf\libBeefySysLib.a components\beef\lib\
```

Add `beef` to your main component:

`main/CMakeLists.txt`:
```cmake
idf_component_register(SRCS "hello_world_main.c"
                       PRIV_REQUIRES spi_flash beef)
```

Minimal `app_main` integration:

```c
void BfpSystem_Init(int version, int flags);
void BfpSystem_SetCommandLine(int argc, char** argv);
uint32_t BfpSystem_TickCount(void);
int PrintF(const char* fmt, ...);
int BeefApp_Init(void);
void BeefApp_Tick(void);
void BeefApp_Shutdown(void);

void app_main(void)
{
    static char beef_arg0[] = "beef";
    static char* beef_argv[] = { beef_arg0, NULL };
    BfpSystem_Init(2, 0);
    BfpSystem_SetCommandLine(1, beef_argv);
    PrintF("Beef runtime linked, tick=%u\n", BfpSystem_TickCount());
    BeefApp_Init();
    BeefApp_Tick();
    BeefApp_Shutdown();
}
```

## 6) Build and flash

```bat
idf.py build
idf.py -p COM4 flash
idf.py -p COM4 monitor
```

## Notes

- IDEHelper must be the Xtensa-capable build for ESP32 targets.
- The runtime libs are built with Xtensa GCC from ESP-IDF.
- The static app libs are built with BeefBuild + esp-llvm backend.
- Linker warnings about `chdir/chmod/getcwd` are expected for baremetal.
