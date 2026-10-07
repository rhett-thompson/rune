@if (@X)==(@Y) @end /*
@echo off
setlocal EnableExtensions DisableDelayedExpansion
cscript //nologo //E:JScript "%~f0" %*
exit /b %errorlevel%
*/
// Built-in Windows JScript handles paths and the pinned JSON metadata.
var fs = new ActiveXObject("Scripting.FileSystemObject");
var shell = new ActiveXObject("WScript.Shell");
function fail(message) { throw new Error(message); }
function writeText(stream, text) {
    try { stream.Write(text); }
    catch (error) { stream.Write(String(text).replace(/[^\x20-\x7e\r\n\t]/g, function(c) { return "\\u" + ("0000" + c.charCodeAt(0).toString(16)).slice(-4); })); }
}
function read(path) { var file = fs.OpenTextFile(path, 1); var text = file.AtEndOfStream ? "" : file.ReadAll(); file.Close(); return text; }
function write(path, text) { var file = fs.CreateTextFile(path, true, false); file.Write(text); file.Close(); }
function value(text, key) {
    var match = new RegExp('"' + key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + '"\\s*:\\s*"([^"\\\\]*)"').exec(text);
    if (!match) fail("Missing source pin: " + key);
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
function directory(path) { path = fs.GetAbsolutePathName(path); if (!fs.FolderExists(path)) fail("Directory does not exist: " + path); return path; }
function hash(path) { var digest = run(["certutil.exe", "-hashfile", path, "SHA256"], true).match(/\b[0-9a-fA-F]{64}\b/); if (!digest) fail("Could not read SHA256: " + path); return digest[0].toUpperCase(); }
try {
    var options = {zig: "zig", target: "Windows"};
    var aliases = {"--r3d-source": "r3d", "-r3dsource": "r3d", "--assimp-source": "assimp", "-assimpsource": "assimp", "--raylib-headers": "headers", "-raylibheaders": "headers", "--zig": "zig", "-zig": "zig", "--target": "target", "-target": "target"};
    var usage = "Usage: tools\\build_r3d_importer.bat --r3d-source <checkout> --assimp-source <checkout> --raylib-headers <directory> [--zig <executable>] [--target Windows|Linux|All]";
    for (var i = 0; i < WScript.Arguments.length; ++i) {
        var argument = WScript.Arguments(i).toLowerCase();
        if (argument == "--help" || argument == "-h") { WScript.Echo(usage); WScript.Quit(0); }
        if (!aliases[argument]) fail("Unknown argument: " + WScript.Arguments(i));
        if (++i >= WScript.Arguments.length) fail("Missing value for " + argument);
        options[aliases[argument]] = WScript.Arguments(i);
    }
    if (!options.r3d || !options.assimp || !options.headers) fail(usage);
    var target = options.target.toLowerCase();
    if (target != "windows" && target != "linux" && target != "all") fail("Unknown target: " + options.target);
    var root = fs.GetParentFolderName(fs.GetParentFolderName(WScript.ScriptFullName));
    var nativeRoot = fs.BuildPath(root, "third_party/r3d-importer");
    var pins = read(fs.BuildPath(nativeRoot, "sources.json"));
    var zigVersion = run([options.zig, "version"], true).replace(/^\s+|\s+$/g, "");
    if (zigVersion != value(pins, "zig")) fail("Expected Zig " + value(pins, "zig") + "; found '" + zigVersion + "'.");
    var r3dSource = directory(options.r3d), assimpSource = directory(options.assimp), raylibHeaders = directory(options.headers);
    var headers = ["raylib.h", "raymath.h"];
    for (var i = 0; i < headers.length; ++i) {
        var headerPath = fs.BuildPath(raylibHeaders, headers[i]);
        if (hash(headerPath) != value(pins, headers[i]).toUpperCase()) fail("Header does not match the pinned raylib revision: " + headerPath);
    }
    var work = fs.BuildPath(root, "build/r3d-importer-" + fs.GetTempName());
    mkdir(work);
    function exportSource(source, revision, name, paths) {
        var destination = fs.BuildPath(work, name), archive = fs.BuildPath(work, name + ".tar");
        mkdir(destination);
        run(["git", "-C", source, "archive", "--format=tar", "--output=" + archive, revision].concat(paths));
        run(["tar.exe", "-xf", archive, "-C", destination]);
        return destination;
    }
    var r3d = exportSource(r3dSource, value(pins, "r3d"), "r3d", ["include", "src", "external/uthash"]);
    var assimp = exportSource(assimpSource, value(pins, "assimp"), "assimp", ["include"]);
    var patch = fs.BuildPath(nativeRoot, "fbx-pivots.patch");
    run(["git", "-C", r3d, "init", "--quiet"]);
    run(["git", "-C", r3d, "apply", "--check", patch]);
    run(["git", "-C", r3d, "apply", patch]);
    run(["git", "-C", r3d, "apply", "--reverse", "--check", patch]);
    var headerRoot = fs.BuildPath(work, "headers"); mkdir(fs.BuildPath(headerRoot, "assimp"));
    for (var i = 0; i < headers.length; ++i) fs.CopyFile(fs.BuildPath(raylibHeaders, headers[i]), fs.BuildPath(headerRoot, headers[i]), true);
    write(fs.BuildPath(headerRoot, "r3d_config.h"), '#define R3D_SUPPORT_ASSIMP\n#define R3D_TRACELOG(level, msg, ...) TraceLog(level, "R3D: " msg, ##__VA_ARGS__)\n');
    write(fs.BuildPath(headerRoot, "assimp/config.h"), read(fs.BuildPath(assimp, "include/assimp/config.h.in")).replace(/#cmakedefine ASSIMP_DOUBLE_PRECISION 1/g, "/* float precision */"));
    fs.CopyFile(fs.BuildPath(nativeRoot, "animation_clips.c"), fs.BuildPath(work, "animation_clips.c"), true);
    write(fs.BuildPath(work, "importer.c"), '#include "r3d/src/r3d_importer.c"\n#include "animation_clips.c"\n');
    shell.Environment("PROCESS")("ZIG_GLOBAL_CACHE_DIR") = fs.BuildPath(root, "build/zig-cache");
    var platforms = target == "all" ? ["windows", "linux"] : [target];
    var outputs = [];
    for (var i = 0; i < platforms.length; ++i) {
        var windows = platforms[i] == "windows";
        var object = fs.BuildPath(work, windows ? "importer.obj" : "importer.o");
        var name = windows ? "importer.lib" : "libimporter.a", library = fs.BuildPath(work, name);
        run([options.zig, "cc", "-target", windows ? "x86_64-windows-msvc" : "x86_64-linux-gnu", "-c", fs.BuildPath(work, "importer.c"), "-O2", "-DNDEBUG", "-D_CRT_SECURE_NO_WARNINGS", "-std=c11", "-DR3D_LoadImporter=Rune_LoadImporter", "-DR3D_LoadImporterFromMemory=Rune_LoadImporterFromMemory", "-DR3D_UnloadImporter=Rune_UnloadImporter", "-I" + headerRoot, "-I" + fs.BuildPath(r3d, "include"), "-I" + fs.BuildPath(r3d, "external/uthash"), "-I" + fs.BuildPath(assimp, "include"), "-o", object]);
        run([options.zig, "ar", "rcs", library, object]);
        outputs.push({source: library, directory: fs.BuildPath(nativeRoot, platforms[i]), name: name});
    }
    // Publish only after every requested compilation succeeds.
    for (var i = 0; i < outputs.length; ++i) {
        mkdir(outputs[i].directory);
        var destination = fs.BuildPath(outputs[i].directory, outputs[i].name);
        fs.CopyFile(outputs[i].source, destination, true);
        writeText(WScript.StdOut,hash(destination) + "  " + destination + "\n");
    }
} catch (error) { writeText(WScript.StdErr,"Error: " + error.message + "\n"); WScript.Quit(1); }
