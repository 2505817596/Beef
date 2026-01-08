param(
    [ValidateSet("x64", "arm32")]
    [string]$Arch = "x64",
    [string]$Zig = "",
    [string]$BuildDir = "",
    [string]$TargetTriple = "",
    [string]$ZigTarget = "",
    [string]$ArmFlags = "-mcpu=cortex_a7 -mfpu=neon -mfloat-abi=hard",
    [switch]$EnableFFI,
    [string]$FFITargetDir = "",
    [string]$FFIArch = "",
    [string]$OutDir = "",
    [switch]$AlsoCopyToDist
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($Zig)) {
    if (-not [string]::IsNullOrWhiteSpace($env:BEEF_ZIG_EXE)) {
        $Zig = $env:BEEF_ZIG_EXE
    } elseif (-not [string]::IsNullOrWhiteSpace($env:ZIG)) {
        $Zig = $env:ZIG
    } elseif (Test-Path "D:\zig-x86_64-windows-0.16.0-dev.238+580b6d1fa\zig.exe") {
        $Zig = "D:\zig-x86_64-windows-0.16.0-dev.238+580b6d1fa\zig.exe"
    }
}

if ([string]::IsNullOrWhiteSpace($Zig) -or -not (Test-Path $Zig)) {
    throw "Zig not found. Pass -Zig or set BEEF_ZIG_EXE."
}

if ($Arch -eq "x64") {
    if ([string]::IsNullOrWhiteSpace($TargetTriple)) { $TargetTriple = "x86_64-unknown-linux-musl" }
    if ([string]::IsNullOrWhiteSpace($ZigTarget)) { $ZigTarget = "x86_64-linux-musl" }
    if ([string]::IsNullOrWhiteSpace($BuildDir)) { $BuildDir = Join-Path $root "build_musl_zig_rt" }
    if ([string]::IsNullOrWhiteSpace($FFIArch)) { $FFIArch = "x86" }
} else {
    if ([string]::IsNullOrWhiteSpace($TargetTriple)) { $TargetTriple = "armv7-unknown-linux-musleabihf" }
    if ([string]::IsNullOrWhiteSpace($ZigTarget)) { $ZigTarget = "arm-linux-musleabihf" }
    if ([string]::IsNullOrWhiteSpace($BuildDir)) { $BuildDir = Join-Path $root "build_musl_arm32" }
    if ([string]::IsNullOrWhiteSpace($FFIArch)) { $FFIArch = "arm" }
}

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $root ("IDE\dist\rt\" + $TargetTriple)
}

if ([string]::IsNullOrWhiteSpace($FFITargetDir)) {
    $FFITargetDir = $TargetTriple
}

$cFlags = "--target=$ZigTarget -fno-sanitize=all"
$cxxFlags = "--target=$ZigTarget -fno-sanitize=all"
if ($Arch -eq "arm32" -and -not [string]::IsNullOrWhiteSpace($ArmFlags)) {
    $cFlags = "$cFlags $ArmFlags"
    $cxxFlags = "$cxxFlags $ArmFlags"
}

$cmakeArgs = @(
    "-G", "Ninja",
    "-S", $root,
    "-B", $BuildDir,
    "-DBF_ONLY_RUNTIME=1",
    "-DCMAKE_SYSTEM_NAME=Linux",
    "-DCMAKE_C_COMPILER=$Zig",
    "-DCMAKE_C_COMPILER_ARG1=cc",
    "-DCMAKE_CXX_COMPILER=$Zig",
    "-DCMAKE_CXX_COMPILER_ARG1=c++",
    "-DCMAKE_C_FLAGS=$cFlags",
    "-DCMAKE_CXX_FLAGS=$cxxFlags",
    "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY",
    "-DCMAKE_BUILD_TYPE=Release"
)

if ($Arch -eq "arm32") {
    $cmakeArgs += "-DCMAKE_SYSTEM_PROCESSOR=arm"
}

if ($EnableFFI) {
    $cmakeArgs += "-UBF_DISABLE_FFI"
    $cmakeArgs += "-DBF_FFI_TARGET_DIR=$FFITargetDir"
    $cmakeArgs += "-DBF_FFI_ARCH=$FFIArch"
} else {
    $cmakeArgs += "-DBF_DISABLE_FFI=1"
}

Write-Host "Configuring: $BuildDir"
& cmake @cmakeArgs

Write-Host "Building (single-thread to avoid Zig OOM)"
& cmake --build $BuildDir --config Release -- -j 1

$binDir = Join-Path $BuildDir "Release\bin"
if (-not (Test-Path $binDir)) {
    throw "Build output not found: $binDir"
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
Copy-Item -Force (Join-Path $binDir "libBeefRT.a") (Join-Path $OutDir "libBeefRT.a")
Copy-Item -Force (Join-Path $binDir "libBeefySysLib.a") (Join-Path $OutDir "libBeefySysLib.a")

if ($AlsoCopyToDist) {
    $distDir = Join-Path $root "IDE\dist"
    Copy-Item -Force (Join-Path $binDir "libBeefRT.a") (Join-Path $distDir "libBeefRT.a")
    Copy-Item -Force (Join-Path $binDir "libBeefySysLib.a") (Join-Path $distDir "libBeefySysLib.a")
}

Write-Host "Done. Runtime libs in: $OutDir"
