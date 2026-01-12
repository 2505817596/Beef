param(
  [string]$WorkspacePath = "D:\\fairy\\beefesp32demo",
  [string]$IdfProjectPath = "D:\\fairy\\esp32demo\\hello_world",
  [string]$IdfRoot = "D:\\fairy\\esp32demo\\esp-idf",
  [string]$EspLlvmRoot = "D:\\fairy\\esp-llvm-msvc",
  [switch]$CopyRuntime,
  [switch]$Flash,
  [switch]$Monitor,
  [string]$Port = "COM4"
)

$ErrorActionPreference = "Stop"

function Require-Path([string]$Path) {
  if (-not (Test-Path $Path)) {
    throw "Missing path: $Path"
  }
}

$BeefRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$BeefBuild = Join-Path $BeefRoot "IDE\\dist\\BeefBuild.exe"
$BeefRtDir = Join-Path $BeefRoot "IDE\\dist\\rt\\xtensa-esp32s3-elf"
$BeefAr = Join-Path $EspLlvmRoot "build\\bin\\llvm-ar.exe"

$BeefLibOut = Join-Path $WorkspacePath "build\\Release_ESP32"
$BeefAppLib = Join-Path $BeefLibOut "beefesp32demo\\beefesp32demo.a"
$CorlibLib = Join-Path $BeefLibOut "corlib\\corlib.a"

$BeefComponentLibDir = Join-Path $IdfProjectPath "components\\beef\\lib"

Require-Path $BeefBuild
Require-Path $BeefRtDir
Require-Path $BeefAr
Require-Path $WorkspacePath
Require-Path $IdfProjectPath
Require-Path $IdfRoot

$env:BEEF_RT_DIR = $BeefRtDir
$env:BEEF_AR = $BeefAr

Write-Host "[1/3] Build Beef ESP32 libs"
& $BeefBuild -workspace="$WorkspacePath" -config=Release -platform=ESP32
if ($LASTEXITCODE -ne 0) { throw "BeefBuild failed" }

Require-Path $BeefAppLib
Require-Path $CorlibLib

Write-Host "[2/3] Copy libs into ESP-IDF component"
New-Item -ItemType Directory -Force -Path $BeefComponentLibDir | Out-Null
Copy-Item -Force $BeefAppLib $BeefComponentLibDir
Copy-Item -Force $CorlibLib $BeefComponentLibDir

if ($CopyRuntime) {
  Copy-Item -Force (Join-Path $BeefRtDir "libBeefRT.a") $BeefComponentLibDir
  Copy-Item -Force (Join-Path $BeefRtDir "libBeefySysLib.a") $BeefComponentLibDir
}

Write-Host "[3/3] ESP-IDF build"
Push-Location $IdfProjectPath
$cmd = "`"$IdfRoot\\export.bat`" && idf.py build"
& cmd /c $cmd
if ($LASTEXITCODE -ne 0) { throw "idf.py build failed" }

if ($Flash) {
  $cmd = "`"$IdfRoot\\export.bat`" && idf.py -p $Port flash"
  & cmd /c $cmd
  if ($LASTEXITCODE -ne 0) { throw "idf.py flash failed" }
}

if ($Monitor) {
  $cmd = "`"$IdfRoot\\export.bat`" && idf.py -p $Port monitor"
  & cmd /c $cmd
  if ($LASTEXITCODE -ne 0) { throw "idf.py monitor failed" }
}

Pop-Location
Write-Host "Done."
