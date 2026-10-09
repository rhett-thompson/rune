@if (@X)==(@Y) @end /*
@echo off
setlocal EnableExtensions DisableDelayedExpansion
cscript //nologo //E:JScript "%~f0" %*
exit /b %errorlevel%
*/
// Export and build the pinned native light and shader modules; never edit a checkout.
var fs = new ActiveXObject("Scripting.FileSystemObject"), shell = new ActiveXObject("WScript.Shell");
function fail(message) { throw new Error(message); }
function read(path) { var f = fs.OpenTextFile(path, 1), text = f.AtEndOfStream ? "" : f.ReadAll(); f.Close(); return text; }
function write(path, text) { var f = fs.CreateTextFile(path, true, false); f.Write(text); f.Close(); }
function pin(text, key) {
    var match = new RegExp('"' + key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + '"\\s*:\\s*"([^"\\\\]*)"').exec(text);
    if (!match) fail("Missing source pin: " + key);
    return match[1];
}
function quote(text) {
    text = String(text);
    if (/["\r\n%]/.test(text)) fail("Unsupported quote, newline, or percent sign in command argument.");
    return '"' + text.replace(/(\\+)$/, "$1$1") + '"';
}
function run(args) {
    var output = fs.BuildPath(fs.GetSpecialFolder(2), fs.GetTempName()), line = [];
    for (var i = 0; i < args.length; ++i) line.push(quote(args[i]));
    var status = shell.Run('cmd.exe /d /v:off /s /c "' + line.join(" ") + ' >' + quote(output) + ' 2>&1"', 0, true);
    var text = fs.FileExists(output) ? read(output) : "";
    if (fs.FileExists(output)) fs.DeleteFile(output);
    if (status) fail("Command failed (" + status + "): " + args[0] + "\n" + text);
    return text;
}
function mkdir(path) { if (fs.FolderExists(path)) return; var parent = fs.GetParentFolderName(path); if (parent && !fs.FolderExists(parent)) mkdir(parent); fs.CreateFolder(path); }
function directory(path) { path = fs.GetAbsolutePathName(path); if (!fs.FolderExists(path)) fail("Directory does not exist: " + path); return path; }
function hash(path) { var digest = run(["certutil.exe", "-hashfile", path, "SHA256"]).match(/\b[0-9a-fA-F]{64}\b/); if (!digest) fail("Could not hash: " + path); return digest[0].toUpperCase(); }
try {
    var options = {zig: "zig", python: "python", target: "Windows"};
    var aliases = {"--r3d-source": "r3d", "--raylib-headers": "headers", "--zig": "zig", "--python": "python", "--target": "target"};
    var usage = "Usage: tools\\build_r3d_shadows.bat --r3d-source <checkout> --raylib-headers <directory> [--zig <executable>] [--python <Python 3 executable>] [--target Windows|Linux|All]";
    for (var i = 0; i < WScript.Arguments.length; ++i) {
        var argument = String(WScript.Arguments(i)).toLowerCase();
        if (argument == "--help" || argument == "-h") { WScript.Echo(usage); WScript.Quit(0); }
        if (!aliases[argument]) fail("Unknown argument: " + WScript.Arguments(i));
        if (++i >= WScript.Arguments.length) fail("Missing value for " + argument);
        options[aliases[argument]] = String(WScript.Arguments(i));
    }
    if (!options.r3d || !options.headers) fail(usage);
    var target = options.target.toLowerCase();
    if (target != "windows" && target != "linux" && target != "all") fail("Unknown target: " + options.target);
    var root = fs.GetParentFolderName(fs.GetParentFolderName(WScript.ScriptFullName));
    var nativeRoot = fs.BuildPath(root, "third_party/r3d-shadows");
    var pins = read(fs.BuildPath(root, "third_party/r3d-importer/sources.json"));
    var zigVersion = run([options.zig, "version"]).replace(/^\s+|\s+$/g, "");
    if (zigVersion != pin(pins, "zig")) fail("Expected Zig " + pin(pins, "zig") + "; found '" + zigVersion + "'.");
    if (!/^Python 3\./.test(run([options.python, "--version"]))) fail("Python 3 is required to embed the pinned shader sources.");
    var r3dSource = directory(options.r3d), raylibHeaders = directory(options.headers);
    var headers = ["raylib.h", "raymath.h"];
    for (var i = 0; i < headers.length; ++i) {
        var path = fs.BuildPath(raylibHeaders, headers[i]);
        if (hash(path) != pin(pins, headers[i]).toUpperCase()) fail("Header does not match the pinned raylib revision: " + path);
    }
    var work = fs.BuildPath(root, "build/r3d-shadows-" + fs.GetTempName()); mkdir(work);
    var source = fs.BuildPath(work, "r3d"); mkdir(source);
    var archive = fs.BuildPath(work, "r3d.tar");
    run(["git", "-C", r3dSource, "archive", "--format=tar", "--output=" + archive, pin(pins, "r3d"), "include", "src", "external/glad", "shaders", "scripts"]);
    run(["tar.exe", "-xf", archive, "-C", source]);
    // Give the export its own Git root; otherwise git apply can find Rune's parent checkout.
    run(["git", "-C", source, "init", "--quiet"]);
    var patch = fs.BuildPath(nativeRoot, "stable-projection.patch");
    run(["git", "-C", source, "apply", "--check", patch]);
    run(["git", "-C", source, "apply", patch]);
    run(["git", "-C", source, "apply", "--reverse", "--check", patch]);
    var receiverPatch = fs.BuildPath(nativeRoot, "receiver-plane.patch");
    run(["git", "-C", source, "apply", "--check", receiverPatch]);
    run(["git", "-C", source, "apply", receiverPatch]);
    run(["git", "-C", source, "apply", "--reverse", "--check", receiverPatch]);
    var ssaoPatch = fs.BuildPath(nativeRoot, "ssao-reconstruction.patch");
    run(["git", "-C", source, "apply", "--check", ssaoPatch]);
    run(["git", "-C", source, "apply", ssaoPatch]);
    run(["git", "-C", source, "apply", "--reverse", "--check", ssaoPatch]);
    var headerRoot = fs.BuildPath(work, "headers"); mkdir(headerRoot);
    for (var i = 0; i < headers.length; ++i) fs.CopyFile(fs.BuildPath(raylibHeaders, headers[i]), fs.BuildPath(headerRoot, headers[i]), true);
    fs.CopyFile(fs.BuildPath(nativeRoot, "r3d_config.h"), fs.BuildPath(headerRoot, "r3d_config.h"), true);
    var generated = fs.BuildPath(work, "generated");
    run([options.python, fs.BuildPath(root, "tools/generate_r3d_shader_headers.py"), "--source", source, "--output", generated]);
    shell.Environment("PROCESS")("ZIG_GLOBAL_CACHE_DIR") = fs.BuildPath(root, "build/zig-cache");
    var platforms = target == "all" ? ["windows", "linux"] : [target], outputs = [];
    for (var i = 0; i < platforms.length; ++i) {
        var windows = platforms[i] == "windows";
        var modules = [{source: "r3d_light.c", output: "shadows"}, {source: "r3d_shader.c", output: "receiver_shader"}];
        for (var m = 0; m < modules.length; ++m) {
            var name = modules[m].output + (windows ? ".obj" : ".o");
            var object = fs.BuildPath(work, name);
            var compile = [options.zig, "cc", "-target", windows ? "x86_64-windows-msvc" : "x86_64-linux-gnu", "-c", fs.BuildPath(source, "src/modules/" + modules[m].source), "-O2", "-g0", "-DNDEBUG", "-D_CRT_SECURE_NO_WARNINGS", "-std=c11", "-I" + headerRoot, "-I" + fs.BuildPath(source, "include"), "-I" + fs.BuildPath(source, "external/glad"), "-I" + generated, "-o", object];
            if (!windows) compile.push("-fPIC");
            run(compile);
            outputs.push({source: object, directory: fs.BuildPath(nativeRoot, platforms[i]), name: name});
        }
    }
    // Publish only after every requested compilation succeeds.
    for (var i = 0; i < outputs.length; ++i) {
        mkdir(outputs[i].directory);
        var destination = fs.BuildPath(outputs[i].directory, outputs[i].name);
        fs.CopyFile(outputs[i].source, destination, true);
        WScript.Echo(hash(destination) + "  " + destination);
    }
} catch (error) { WScript.StdErr.WriteLine("Error: " + error.message); WScript.Quit(1); }
