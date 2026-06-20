@echo off

setlocal EnableDelayedExpansion

set "SavedPath=%PATH%"
set "PATH="
set "Path=!SavedPath!"
set "MSBUILDDISABLENODEREUSE=1"

for /f "usebackq tokens=*" %%i in (`"%~dp0\vswhere" -prerelease -latest -products * -requires Microsoft.Component.MSBuild -property installationPath`) do (
  set "VcInstallDir=%%i"
)

if not defined VcInstallDir (
  echo MSBuild installation not found.
  exit /b 1
)

SET "VsBuildDir=%VcInstallDir%\MSBuild\15.0"
@IF EXIST "%VcInstallDir%\MSBuild\Current" SET "VsBuildDir=%VcInstallDir%\MSBuild\Current"

set "ToolsetArg="
set "HasToolsetArg="
set "NodeReuseArg=/nr:false"
set "TrackFileAccessArg=/p:TrackFileAccess=false"
set "UseMultiToolTaskArg=/p:UseMultiToolTask=false"
for %%a in (%*) do (
  echo %%a | "%SystemRoot%\System32\findstr.exe" /I /C:"PlatformToolset=" >nul
  if not errorlevel 1 set "HasToolsetArg=1"
  echo %%a | "%SystemRoot%\System32\findstr.exe" /I /C:"/nr:" >nul
  if not errorlevel 1 set "NodeReuseArg="
  echo %%a | "%SystemRoot%\System32\findstr.exe" /I /C:"/nodeReuse:" >nul
  if not errorlevel 1 set "NodeReuseArg="
  echo %%a | "%SystemRoot%\System32\findstr.exe" /I /C:"TrackFileAccess=" >nul
  if not errorlevel 1 set "TrackFileAccessArg="
  echo %%a | "%SystemRoot%\System32\findstr.exe" /I /C:"UseMultiToolTask=" >nul
  if not errorlevel 1 set "UseMultiToolTaskArg="
)
if not defined HasToolsetArg (
  if not exist "%VcInstallDir%\MSBuild\Microsoft\VC\v143\Microsoft.Cpp.Default.props" (
    for /d %%v in ("%VcInstallDir%\MSBuild\Microsoft\VC\v*") do (
      for /d %%t in ("%%v\Platforms\x64\PlatformToolsets\v*") do (
        set "ToolsetArg=/p:PlatformToolset=%%~nxt"
        goto FoundToolset
      )
    )
  )
)

:FoundToolset

"%VsBuildDir%\Bin\MSBuild.exe" %NodeReuseArg% %* %ToolsetArg% %TrackFileAccessArg% %UseMultiToolTaskArg%
