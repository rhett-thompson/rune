@if (@X)==(@Y) @end /*
@echo off
setlocal EnableExtensions DisableDelayedExpansion
cscript.exe //nologo //E:JScript "%~f0" %*
exit /b %errorlevel%
*/
// Print a complete toolset root for tools/odin.bat; do not change the caller's environment.
var fs = new ActiveXObject("Scripting.FileSystemObject"), shell = new ActiveXObject("WScript.Shell");
var env = shell.Environment("Process");
var arch = WScript.Arguments.length ? WScript.Arguments.Item(0) : "x64";
function join(root, path) { return fs.BuildPath(root, path); }
function trim(text) { return text.replace(/^\s+|\s+$/g, ""); }
function complete(root) {
    if (!root) return false;
    return fs.FileExists(join(root, "bin\\Host" + arch + "\\" + arch + "\\link.exe")) &&
        fs.FileExists(join(root, "lib\\" + arch + "\\libcmt.lib")) &&
        fs.FileExists(join(root, "lib\\" + arch + "\\vcruntime.lib"));
}
function newestFirst(a, b) {
    var av = fs.GetFileName(a).split("."), bv = fs.GetFileName(b).split(".");
    for (var i = 0; i < Math.max(av.length, bv.length); i++) {
        var difference = Number(bv[i] || 0) - Number(av[i] || 0);
        if (difference) return difference;
    }
    return 0;
}
function find() {
    // Keep a usable explicit/developer-shell selection, including portable MSVC.
    var configured = env("VCToolsInstallDir");
    if (complete(configured)) return configured;
    var paths = env("PATH").split(";");
    for (var i = 0; i < paths.length; i++) {
        var entry = trim(paths[i]).replace(/^"|"$/g, "").replace(/\\+$/, "");
        var suffix = new RegExp("\\\\bin\\\\Host" + arch + "\\\\" + arch + "$", "i");
        if (suffix.test(entry)) {
            var root = entry.replace(suffix, "");
            if (complete(root)) return root;
        }
    }

    // Enumerate actual version folders rather than relying on the default-version file.
    var programFiles = env("ProgramFiles(x86)") || env("ProgramFiles");
    if (!programFiles) return "";
    var vswhere = join(programFiles, "Microsoft Visual Studio\\Installer\\vswhere.exe");
    if (!fs.FileExists(vswhere)) return "";
    var process = shell.Exec('"' + vswhere + '" -products * -sort -property installationPath');
    var output = process.StdOut.ReadAll();
    var error = process.StdErr.ReadAll();
    if (process.ExitCode) throw new Error("vswhere failed: " + trim(error));
    var installations = output.split(/\r?\n/);
    for (var j = 0; j < installations.length; j++) {
        var installation = trim(installations[j]);
        if (!installation) continue;
        var directory = join(installation, "VC\\Tools\\MSVC");
        if (!fs.FolderExists(directory)) continue;
        var candidates = [], folders = new Enumerator(fs.GetFolder(directory).SubFolders);
        for (; !folders.atEnd(); folders.moveNext()) {
            var folder = folders.item();
            if (/^\d+(\.\d+)+$/.test(folder.Name)) candidates.push(folder.Path);
        }
        candidates.sort(newestFirst);
        for (var k = 0; k < candidates.length; k++) {
            if (complete(candidates[k])) return candidates[k];
        }
    }
    return "";
}
try {
    if (arch !== "x64" && arch !== "x86") throw new Error("Expected MSVC architecture x64 or x86.");
    var selected = find();
    if (!selected) throw new Error("No complete MSVC " + arch + " toolset found. Install Visual Studio's Desktop development with C++ workload and Windows SDK, or set VCToolsInstallDir to a complete toolset.");
    WScript.Echo(selected);
} catch (error) {
    WScript.StdErr.WriteLine("MSVC discovery: " + error.message);
    WScript.Quit(1);
}
