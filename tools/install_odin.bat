@if (@X)==(@Y) @end /*
@echo off
setlocal EnableExtensions DisableDelayedExpansion
cscript //nologo //E:JScript "%~f0" %*
exit /b %errorlevel%
*/
// Windows includes this JScript host; no PowerShell or other runtime is needed.
var fs = new ActiveXObject("Scripting.FileSystemObject");
var shell = new ActiveXObject("WScript.Shell");
function fail(message) { throw new Error(message); }
function writeText(stream, text) {
    try { stream.Write(text); }
    catch (error) { stream.Write(String(text).replace(/[^\x20-\x7e\r\n\t]/g, function(c) { return "\\u" + ("0000" + c.charCodeAt(0).toString(16)).slice(-4); })); }
}
function read(path) { var file = fs.OpenTextFile(path, 1); var text = file.AtEndOfStream ? "" : file.ReadAll(); file.Close(); return text; }
function value(text, key) {
    var match = new RegExp('"' + key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + '"\\s*:\\s*"([^"\\\\]*)"').exec(text);
    if (!match) fail("Missing toolchain property: " + key);
    return match[1];
}
function quote(text) {
    text = String(text);
    if (/["\r\n%]/.test(text)) fail("Unsupported quote, newline, or percent sign in command argument.");
    return '"' + text.replace(/(\\+)$/, "$1$1") + '"';
}
function run(args, quiet) {
    var output = fs.BuildPath(fs.GetSpecialFolder(2), fs.GetTempName());
    var command = [];
    for (var i = 0; i < args.length; ++i) command.push(quote(args[i]));
    var status = shell.Run('cmd.exe /d /v:off /s /c "' + command.join(" ") + ' >' + quote(output) + ' 2>&1"', 0, true);
    var text = fs.FileExists(output) ? read(output) : "";
    if (fs.FileExists(output)) fs.DeleteFile(output);
    if (!quiet && text) writeText(WScript.StdOut,text);
    if (status) fail("Command failed (" + status + "): " + args[0] + (quiet ? "\n" + text : ""));
    return text;
}
function mkdir(path) { if (fs.FolderExists(path)) return; var parent = fs.GetParentFolderName(path); if (parent && !fs.FolderExists(parent)) mkdir(parent); fs.CreateFolder(path); }
function findCompilers(path, results) {
    var folder = fs.GetFolder(path);
    if (fs.FileExists(fs.BuildPath(path, "odin.exe")) && fs.FolderExists(fs.BuildPath(path, "core"))) results.push(fs.BuildPath(path, "odin.exe"));
    for (var folders = new Enumerator(folder.SubFolders); !folders.atEnd(); folders.moveNext()) findCompilers(folders.item().Path, results);
}
try {
    var destination = "";
    for (var i = 0; i < WScript.Arguments.length; ++i) {
        var argument = WScript.Arguments(i).toLowerCase();
        if (argument == "--help" || argument == "-h") { WScript.Echo("Usage: tools\\install_odin.bat --destination <new-directory>"); WScript.Quit(0); }
        if (argument != "--destination" && argument != "-destination") fail("Unknown argument: " + WScript.Arguments(i));
        if (++i >= WScript.Arguments.length) fail("Missing destination.");
        destination = WScript.Arguments(i);
    }
    if (!destination) fail("Usage: tools\\install_odin.bat --destination <new-directory>");
    var environment = shell.Environment("PROCESS");
    if (String(environment("PROCESSOR_ARCHITECTURE")).toUpperCase() != "AMD64" && String(environment("PROCESSOR_ARCHITEW6432")).toUpperCase() != "AMD64") fail("The pinned toolchain installer currently supports Windows AMD64.");
    var root = fs.GetParentFolderName(fs.GetParentFolderName(WScript.ScriptFullName));
    var pins = read(fs.BuildPath(root, "toolchain.json"));
    var archiveSection = /"windows-amd64"\s*:\s*\{([^}]+)\}/.exec(pins);
    if (!archiveSection) fail("No Odin archive is configured for windows-amd64.");
    var name = value(archiveSection[1], "name"), checksum = value(archiveSection[1], "sha256");
    if (!/^[0-9a-f]{64}$/.test(checksum)) fail("No checksummed Odin archive is configured for windows-amd64.");
    if (/[\\/]/.test(name) || !name || name == "." || name == "..") fail("Invalid Odin archive name.");
    destination = fs.GetAbsolutePathName(destination);
    if (fs.FolderExists(destination) || fs.FileExists(destination)) fail("Destination already exists: " + destination + ". Choose a new directory.");
    mkdir(fs.GetParentFolderName(destination));
    fs.CreateFolder(destination);
    var archive = fs.BuildPath(destination, name);
    run(["curl.exe", "--fail", "--location", "--output", archive, "https://github.com/odin-lang/Odin/releases/download/" + value(pins, "odin_release") + "/" + name]);
    var digest = run(["certutil.exe", "-hashfile", archive, "SHA256"], true).match(/\b[0-9a-fA-F]{64}\b/);
    if (!digest || digest[0].toLowerCase() != checksum) fail("Odin archive checksum mismatch; nothing was extracted.");
    run(["tar.exe", "-xf", archive, "-C", destination]);
    var compilers = []; findCompilers(destination, compilers);
    if (compilers.length != 1) fail("Expected exactly one compiler with its core library in the archive.");
    run([compilers[0], "version"]);
    writeText(WScript.StdOut,"Installed Odin. Add this directory to PATH: " + fs.GetParentFolderName(compilers[0]) + "\n");
} catch (error) { writeText(WScript.StdErr,"Error: " + error.message + "\n"); WScript.Quit(1); }
