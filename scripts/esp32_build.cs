using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;

var options = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
var flags = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

for (int i = 0; i < args.Length; i++)
{
    var arg = args[i];
    if (!arg.StartsWith("-"))
        continue;

    var trimmed = arg.TrimStart('-');
    if (trimmed.Length == 0)
        continue;

    string? value = null;
    var eqIndex = trimmed.IndexOf('=');
    if (eqIndex >= 0)
    {
        value = trimmed[(eqIndex + 1)..];
        trimmed = trimmed[..eqIndex];
    }
    else if (i + 1 < args.Length && !args[i + 1].StartsWith("-"))
    {
        value = args[++i];
    }

    if (string.IsNullOrWhiteSpace(trimmed))
        continue;

    if (value == null)
        flags.Add(trimmed);
    else
        options[trimmed] = value;
}

if (HasFlag("Help") || HasFlag("h") || HasFlag("?"))
{
    PrintUsage();
    return;
}

string workspacePath = GetOpt("WorkspacePath", @"D:\fairy\beefesp32demo");
string idfProjectPath = GetOpt("IdfProjectPath", @"D:\fairy\esp32demo\hello_world");
string idfRoot = GetOpt("IdfRoot", @"D:\fairy\esp32demo\esp-idf");
string espLlvmRoot = GetOpt("EspLlvmRoot", @"D:\fairy\esp-llvm-msvc");
string port = GetOpt("Port", "COM4");
string? beefRootOpt = GetOptNullable("BeefRoot");
int baud = GetOptInt("Baud", 921600);

bool copyRuntime = HasFlag("CopyRuntime");
bool flash = HasFlag("Flash");
bool monitor = HasFlag("Monitor");

string beefRoot = ResolveBeefRoot(beefRootOpt);

string beefBuild = Path.Combine(beefRoot, "IDE", "dist", "BeefBuild.exe");
string beefRtDir = Path.Combine(beefRoot, "IDE", "dist", "rt", "xtensa-esp32s3-elf");
string beefAr = Path.Combine(espLlvmRoot, "build", "bin", "llvm-ar.exe");

string beefLibOut = Path.Combine(workspacePath, "build", "Release_ESP32");
string beefAppLib = Path.Combine(beefLibOut, "beefesp32demo", "beefesp32demo.a");
string corlibLib = Path.Combine(beefLibOut, "corlib", "corlib.a");

string beefComponentLibDir = Path.Combine(idfProjectPath, "components", "beef", "lib");

RequirePath(beefBuild);
RequirePath(beefRtDir);
RequirePath(beefAr);
RequirePath(workspacePath);
RequirePath(idfProjectPath);
RequirePath(idfRoot);

var beefEnv = new Dictionary<string, string>
{
    ["BEEF_RT_DIR"] = beefRtDir,
    ["BEEF_AR"] = beefAr,
};

Console.WriteLine("[1/3] Build Beef ESP32 libs");
RunProcess(beefBuild, $"-workspace=\"{workspacePath}\" -config=Release -platform=ESP32", beefEnv);

RequirePath(beefAppLib);
RequirePath(corlibLib);

Console.WriteLine("[2/3] Copy libs into ESP-IDF component");
Directory.CreateDirectory(beefComponentLibDir);
File.Copy(beefAppLib, Path.Combine(beefComponentLibDir, Path.GetFileName(beefAppLib)), overwrite: true);
File.Copy(corlibLib, Path.Combine(beefComponentLibDir, Path.GetFileName(corlibLib)), overwrite: true);

if (copyRuntime)
{
    File.Copy(Path.Combine(beefRtDir, "libBeefRT.a"), Path.Combine(beefComponentLibDir, "libBeefRT.a"), overwrite: true);
    File.Copy(Path.Combine(beefRtDir, "libBeefySysLib.a"), Path.Combine(beefComponentLibDir, "libBeefySysLib.a"), overwrite: true);
}

Console.WriteLine("[3/3] ESP-IDF build");
string exportBat = Path.Combine(idfRoot, "export.bat");
RunCmd($"chcp 65001 >nul && \"{exportBat}\" && idf.py build", idfProjectPath, MakeIdfEnv(null));

if (flash)
{
    string baudArg = baud > 0 ? $"-b {baud}" : "";
    RunCmd($"chcp 65001 >nul && \"{exportBat}\" && idf.py -p {port} {baudArg} flash", idfProjectPath, MakeIdfEnv(baud));
}

if (monitor)
{
    string baudArg = baud > 0 ? $"-b {baud}" : "";
    RunCmd($"chcp 65001 >nul && \"{exportBat}\" && idf.py -p {port} {baudArg} monitor", idfProjectPath, MakeIdfEnv(baud));
}

Console.WriteLine("Done.");

string GetOpt(string name, string defaultValue)
{
    return options.TryGetValue(name, out var value) ? value : defaultValue;
}

string? GetOptNullable(string name)
{
    return options.TryGetValue(name, out var value) ? value : null;
}

int GetOptInt(string name, int defaultValue)
{
    if (!options.TryGetValue(name, out var value))
        return defaultValue;
    return int.TryParse(value, out var parsed) ? parsed : defaultValue;
}

bool HasFlag(string name)
{
    return flags.Contains(name);
}

void RequirePath(string path)
{
    if (!File.Exists(path) && !Directory.Exists(path))
        throw new Exception($"Missing path: {path}");
}

void RunProcess(string fileName, string arguments, IDictionary<string, string>? env)
{
    var psi = new ProcessStartInfo(fileName, arguments)
    {
        UseShellExecute = false,
        RedirectStandardOutput = false,
        RedirectStandardError = false,
    };

    if (env != null)
    {
        foreach (var kvp in env)
            psi.Environment[kvp.Key] = kvp.Value;
    }

    using var proc = Process.Start(psi) ?? throw new Exception($"Failed to start: {fileName}");
    proc.WaitForExit();
    if (proc.ExitCode != 0)
        throw new Exception($"{fileName} failed with exit code {proc.ExitCode}");
}

void RunCmd(string command, string workingDir, IDictionary<string, string>? env)
{
    var psi = new ProcessStartInfo("cmd.exe", "/c " + command)
    {
        UseShellExecute = false,
        RedirectStandardOutput = false,
        RedirectStandardError = false,
        WorkingDirectory = workingDir,
    };

    if (env != null)
    {
        foreach (var kvp in env)
            psi.Environment[kvp.Key] = kvp.Value;
    }

    using var proc = Process.Start(psi) ?? throw new Exception("Failed to start cmd.exe");
    proc.WaitForExit();
    if (proc.ExitCode != 0)
        throw new Exception($"Command failed with exit code {proc.ExitCode}: {command}");
}

void PrintUsage()
{
    Console.WriteLine("Usage:");
    Console.WriteLine("  dotnet run scripts\\\\esp32_build.cs -- [options]");
    Console.WriteLine();
    Console.WriteLine("Options:");
    Console.WriteLine("  -WorkspacePath <path>   Beef workspace (default: D:\\\\fairy\\\\beefesp32demo)");
    Console.WriteLine("  -IdfProjectPath <path>  ESP-IDF project (default: D:\\\\fairy\\\\esp32demo\\\\hello_world)");
    Console.WriteLine("  -IdfRoot <path>         ESP-IDF root (default: D:\\\\fairy\\\\esp32demo\\\\esp-idf)");
    Console.WriteLine("  -EspLlvmRoot <path>     esp-llvm root (default: D:\\\\fairy\\\\esp-llvm-msvc)");
    Console.WriteLine("  -BeefRoot <path>        Beef repo root (default: current directory)");
    Console.WriteLine("  -Port <COMx>            Serial port (default: COM4)");
    Console.WriteLine("  -Baud <rate>            Flash/monitor baud (default: 921600, 0 = disable)");
    Console.WriteLine("  -CopyRuntime            Copy BeefRT/BeefySysLib into component");
    Console.WriteLine("  -Flash                  Run idf.py flash");
    Console.WriteLine("  -Monitor                Run idf.py monitor");
}

string ResolveBeefRoot(string? explicitRoot)
{
    if (!string.IsNullOrWhiteSpace(explicitRoot))
        return explicitRoot!;

    var current = new DirectoryInfo(Directory.GetCurrentDirectory());
    while (current != null)
    {
        var probe = Path.Combine(current.FullName, "IDE", "dist", "BeefBuild.exe");
        if (File.Exists(probe))
            return current.FullName;
        current = current.Parent;
    }

    return Directory.GetCurrentDirectory();
}

Dictionary<string, string> MakeIdfEnv(int? baudValue)
{
    var env = new Dictionary<string, string>
    {
        ["PYTHONIOENCODING"] = "utf-8",
        ["PYTHONUTF8"] = "1",
    };
    if (baudValue.HasValue && baudValue.Value > 0)
        env["ESPBAUD"] = baudValue.Value.ToString();
    return env;
}
