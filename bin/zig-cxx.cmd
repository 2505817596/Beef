@echo off
set "ZIG_EXE=D:\zig-x86_64-windows-0.16.0-dev.238+580b6d1fa\zig.exe"
if not "%BEEF_ZIG_EXE%"=="" set "ZIG_EXE=%BEEF_ZIG_EXE%"
set "ZIG_TARGET=%BEEF_ZIG_TARGET%"
if "%ZIG_TARGET%"=="" set "ZIG_TARGET=x86_64-linux-musl"
"%ZIG_EXE%" c++ --target=%ZIG_TARGET% %*
