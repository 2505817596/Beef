using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.CompilerServices;

string GetScriptPath([CallerFilePath] string path = "") => path;

string arch = "x64";
string zig = "";
string buildDir = "";
string targetTriple = "";
string zigTarget = "";
string armFlags = "-mcpu=cortex_a7 -mfpu=neon -mfloat-abi=hard";
bool enableFfi = false;
string ffiTargetDir = "";
string ffiArch = "";
string outDir = "";
bool alsoCopyToDist = false;

if (!TryParseArgs(args))
{
    ShowUsage();
    return;
}

string scriptPath = GetScriptPath();
string scriptDir = Path.GetDirectoryName(scriptPath) ?? Directory.GetCurrentDirectory();
string root = Path.GetFullPath(Path.Combine(scriptDir, ".."));

if (string.IsNullOrWhiteSpace(zig))
{
    string? envZig = Environment.GetEnvironmentVariable("BEEF_ZIG_EXE");
    if (!string.IsNullOrWhiteSpace(envZig))
    {
        zig = envZig;
    }
    else
    {
        envZig = Environment.GetEnvironmentVariable("ZIG");
        if (!string.IsNullOrWhiteSpace(envZig))
        {
            zig = envZig;
        }
        else
        {
            const string defaultZig = @"D:\zig-x86_64-windows-0.16.0-dev.238+580b6d1fa\zig.exe";
            if (File.Exists(defaultZig))
            {
                zig = defaultZig;
            }
        }
    }
}

if (string.IsNullOrWhiteSpace(zig) || !File.Exists(zig))
{
    throw new InvalidOperationException("Zig not found. Pass -Zig or set BEEF_ZIG_EXE.");
}

if (string.Equals(arch, "x64", StringComparison.OrdinalIgnoreCase))
{
    if (string.IsNullOrWhiteSpace(targetTriple)) targetTriple = "x86_64-unknown-linux-musl";
    if (string.IsNullOrWhiteSpace(zigTarget)) zigTarget = "x86_64-linux-musl";
    if (string.IsNullOrWhiteSpace(buildDir)) buildDir = Path.Combine(root, "build_musl_zig_rt");
    if (string.IsNullOrWhiteSpace(ffiArch)) ffiArch = "x86";
}
else if (string.Equals(arch, "arm32", StringComparison.OrdinalIgnoreCase))
{
    if (string.IsNullOrWhiteSpace(targetTriple)) targetTriple = "armv7-unknown-linux-musleabihf";
    if (string.IsNullOrWhiteSpace(zigTarget)) zigTarget = "arm-linux-musleabihf";
    if (string.IsNullOrWhiteSpace(buildDir)) buildDir = Path.Combine(root, "build_musl_arm32");
    if (string.IsNullOrWhiteSpace(ffiArch)) ffiArch = "arm";
}
else
{
    throw new InvalidOperationException("Arch must be x64 or arm32.");
}

if (string.IsNullOrWhiteSpace(outDir))
{
    outDir = Path.Combine(root, "IDE", "dist", "rt", targetTriple);
}

if (string.IsNullOrWhiteSpace(ffiTargetDir))
{
    ffiTargetDir = targetTriple;
}

string cFlags = $"--target={zigTarget} -fno-sanitize=all";
string cxxFlags = $"--target={zigTarget} -fno-sanitize=all";
if (string.Equals(arch, "arm32", StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(armFlags))
{
    cFlags = $"{cFlags} {armFlags}";
    cxxFlags = $"{cxxFlags} {armFlags}";
}

var cmakeArgs = new List<string>
{
    "-G", "Ninja",
    "-S", root,
    "-B", buildDir,
    "-DBF_ONLY_RUNTIME=1",
    "-DCMAKE_SYSTEM_NAME=Linux",
    $"-DCMAKE_C_COMPILER={zig}",
    "-DCMAKE_C_COMPILER_ARG1=cc",
    $"-DCMAKE_CXX_COMPILER={zig}",
    "-DCMAKE_CXX_COMPILER_ARG1=c++",
    $"-DCMAKE_C_FLAGS={cFlags}",
    $"-DCMAKE_CXX_FLAGS={cxxFlags}",
    "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY",
    "-DCMAKE_BUILD_TYPE=Release"
};

if (string.Equals(arch, "arm32", StringComparison.OrdinalIgnoreCase))
{
    cmakeArgs.Add("-DCMAKE_SYSTEM_PROCESSOR=arm");
}

if (enableFfi)
{
    cmakeArgs.Add("-UBF_DISABLE_FFI");
    cmakeArgs.Add($"-DBF_FFI_TARGET_DIR={ffiTargetDir}");
    cmakeArgs.Add($"-DBF_FFI_ARCH={ffiArch}");
}
else
{
    cmakeArgs.Add("-DBF_DISABLE_FFI=1");
}

Console.WriteLine($"Configuring: {buildDir}");
RunProcess("cmake", cmakeArgs, root);

Console.WriteLine("Building (single-thread to avoid Zig OOM)");
RunProcess("cmake", new[] { "--build", buildDir, "--config", "Release", "--", "-j", "1" }, root);

string binDir = Path.Combine(buildDir, "Release", "bin");
if (!Directory.Exists(binDir))
{
    throw new DirectoryNotFoundException($"Build output not found: {binDir}");
}

Directory.CreateDirectory(outDir);
File.Copy(Path.Combine(binDir, "libBeefRT.a"), Path.Combine(outDir, "libBeefRT.a"), true);
File.Copy(Path.Combine(binDir, "libBeefySysLib.a"), Path.Combine(outDir, "libBeefySysLib.a"), true);

if (alsoCopyToDist)
{
    string distDir = Path.Combine(root, "IDE", "dist");
    Directory.CreateDirectory(distDir);
    File.Copy(Path.Combine(binDir, "libBeefRT.a"), Path.Combine(distDir, "libBeefRT.a"), true);
    File.Copy(Path.Combine(binDir, "libBeefySysLib.a"), Path.Combine(distDir, "libBeefySysLib.a"), true);
}

Console.WriteLine($"Done. Runtime libs in: {outDir}");

bool TryParseArgs(string[] inputArgs)
{
    for (int i = 0; i < inputArgs.Length; i++)
    {
        string raw = inputArgs[i];
        if (raw == "-h" || raw == "--help" || raw == "/?")
        {
            return false;
        }

        if (!raw.StartsWith("-"))
        {
            throw new InvalidOperationException($"Unknown argument: {raw}");
        }

        string name = raw.StartsWith("--", StringComparison.Ordinal) ? raw[2..] : raw[1..];
        string? value = null;
        int equalsIndex = name.IndexOf('=');
        if (equalsIndex >= 0)
        {
            value = name[(equalsIndex + 1)..];
            name = name[..equalsIndex];
        }

        switch (name.ToLowerInvariant())
        {
            case "arch":
                arch = value ?? GetNextValue(inputArgs, ref i, name);
                break;
            case "zig":
                zig = value ?? GetNextValue(inputArgs, ref i, name);
                break;
            case "builddir":
                buildDir = value ?? GetNextValue(inputArgs, ref i, name);
                break;
            case "targettriple":
                targetTriple = value ?? GetNextValue(inputArgs, ref i, name);
                break;
            case "zigtarget":
                zigTarget = value ?? GetNextValue(inputArgs, ref i, name);
                break;
            case "armflags":
                armFlags = value ?? GetNextValue(inputArgs, ref i, name);
                break;
            case "enableffi":
                enableFfi = ParseBoolValue(name, value, inputArgs, ref i);
                break;
            case "ffitargetdir":
                ffiTargetDir = value ?? GetNextValue(inputArgs, ref i, name);
                break;
            case "ffiarch":
                ffiArch = value ?? GetNextValue(inputArgs, ref i, name);
                break;
            case "outdir":
                outDir = value ?? GetNextValue(inputArgs, ref i, name);
                break;
            case "alsocopytodist":
                alsoCopyToDist = ParseBoolValue(name, value, inputArgs, ref i);
                break;
            default:
                throw new InvalidOperationException($"Unknown argument: {raw}");
        }
    }

    return true;
}

string GetNextValue(string[] inputArgs, ref int index, string name)
{
    if (index + 1 >= inputArgs.Length)
    {
        throw new InvalidOperationException($"Missing value for -{name}.");
    }

    index++;
    return inputArgs[index];
}

bool ParseBoolValue(string name, string? value, string[] inputArgs, ref int index)
{
    if (value == null)
    {
        if (index + 1 < inputArgs.Length && IsBoolLiteral(inputArgs[index + 1]))
        {
            index++;
            value = inputArgs[index];
        }
        else
        {
            return true;
        }
    }

    if (value.Equals("true", StringComparison.OrdinalIgnoreCase)) return true;
    if (value.Equals("false", StringComparison.OrdinalIgnoreCase)) return false;
    throw new InvalidOperationException($"Invalid value for -{name}: {value}. Use true or false.");
}

bool IsBoolLiteral(string text)
{
    return text.Equals("true", StringComparison.OrdinalIgnoreCase)
        || text.Equals("false", StringComparison.OrdinalIgnoreCase);
}

void RunProcess(string fileName, IEnumerable<string> arguments, string workingDirectory)
{
    var info = new ProcessStartInfo(fileName)
    {
        WorkingDirectory = workingDirectory,
        UseShellExecute = false
    };

    foreach (string arg in arguments)
    {
        info.ArgumentList.Add(arg);
    }

    using var process = Process.Start(info);
    if (process == null)
    {
        throw new InvalidOperationException($"Failed to start: {fileName}");
    }

    process.WaitForExit();
    if (process.ExitCode != 0)
    {
        throw new InvalidOperationException($"{fileName} failed with exit code {process.ExitCode}.");
    }
}

void ShowUsage()
{
    Console.WriteLine("zig-build-musl-runtime.cs");
    Console.WriteLine("Usage:");
    Console.WriteLine("  dotnet run scripts/zig-build-musl-runtime.cs -- [options]");
    Console.WriteLine();
    Console.WriteLine("Options:");
    Console.WriteLine("  -Arch x64|arm32");
    Console.WriteLine("  -Zig <path-to-zig.exe>");
    Console.WriteLine("  -BuildDir <path>");
    Console.WriteLine("  -TargetTriple <triple>");
    Console.WriteLine("  -ZigTarget <zig-target>");
    Console.WriteLine("  -ArmFlags \"-mcpu=... -mfpu=... -mfloat-abi=...\"");
    Console.WriteLine("  -EnableFFI [true|false]");
    Console.WriteLine("  -FFITargetDir <dir>");
    Console.WriteLine("  -FFIArch <arch>");
    Console.WriteLine("  -OutDir <path>");
    Console.WriteLine("  -AlsoCopyToDist [true|false]");
}
