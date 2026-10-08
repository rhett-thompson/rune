@if (@X)==(@Y) @end /*
@echo off
setlocal EnableExtensions DisableDelayedExpansion
cscript.exe //nologo //E:JScript "%~f0" %*
exit /b %errorlevel%
*/
// Windows Script Host is built into Windows. The batch entry point keeps the
// JSON, process lifecycle, and file export in this file without another runtime.
var filesystem = new ActiveXObject("Scripting.FileSystemObject");
var shell = new ActiveXObject("WScript.Shell");
var environment = shell.Environment("Process");
var repositoryRoot = filesystem.GetParentFolderName(filesystem.GetParentFolderName(WScript.ScriptFullName));
var workspace = "", commandNumber = 0, gamePid = null, workingTree = false, runtime = false;
function join(parent, child) { return filesystem.BuildPath(parent, child.replace(/\//g, "\\")); }
function trim(value) { return value.replace(/^\s+|\s+$/g, ""); }
function writeLine(stream, text) {
    try { stream.WriteLine(text); }
    catch (error) { stream.WriteLine(String(text).replace(/[^\x20-\x7e\r\n\t]/g, function(character) { return "\\u" + ("0000" + character.charCodeAt(0).toString(16)).slice(-4); })); }
}
function echo(text) { writeLine(WScript.StdOut, text); }
function fail(message) { throw new Error(message); }
function mkdir(path) {
    if (!filesystem.FolderExists(path)) {
        var parent = filesystem.GetParentFolderName(path);
        if (parent && !filesystem.FolderExists(parent)) mkdir(parent);
        filesystem.CreateFolder(path);
    }
}
function readUtf8(path) {
    var stream = new ActiveXObject("ADODB.Stream");
    stream.Type = 2; stream.Charset = "utf-8"; stream.Open(); stream.LoadFromFile(path);
    var text = stream.ReadText(); stream.Close();
    return text.replace(/^\uFEFF/, "");
}
function writeUtf8(path, text) {
    var stream = new ActiveXObject("ADODB.Stream"), bytes = new ActiveXObject("ADODB.Stream");
    stream.Type = 2; stream.Charset = "utf-8"; stream.Open(); stream.WriteText(text);
    stream.Position = 0; stream.Type = 1; stream.Position = 3;
    bytes.Type = 1; bytes.Open(); stream.CopyTo(bytes); bytes.SaveToFile(path, 2);
    bytes.Close(); stream.Close();
}
function command(executable, args, allowFailure) {
    var outputPath = join(workspace || repositoryRoot, workspace ? "command-" + (++commandNumber) + ".log" : "build\\release-preflight-" + filesystem.GetTempName());
    mkdir(filesystem.GetParentFolderName(outputPath));
    environment("RUNE_RELEASE_TARGET") = executable;
    environment("RUNE_RELEASE_OUTPUT") = outputPath;
    var line = '"%RUNE_RELEASE_TARGET%"';
    for (var index = 0; index < args.length; index++) {
        environment("RUNE_RELEASE_ARG" + index) = String(args[index]);
        line += ' "%RUNE_RELEASE_ARG' + index + '%"';
    }
    var exitCode = shell.Run('cmd.exe /d /v:off /s /c "' + line + ' >"%RUNE_RELEASE_OUTPUT%" 2>&1"', 0, true);
    var output = readUtf8(outputPath);
    if (exitCode && !allowFailure) fail("Command failed with exit code " + exitCode + ": " + executable + "\n" + output);
    return { code: exitCode, output: output };
}
// JSON.parse is absent in the Windows JScript host. Parse data explicitly rather
// than evaluating JSON as code, including strict number and escape validation.
function parseJson(text) {
    var position = 0;
    function space() { while (position < text.length && /[ \t\r\n]/.test(text.charAt(position))) position++; }
    function string() {
        var result = "";
        if (text.charAt(position++) !== '"') fail("Invalid JSON string.");
        while (position < text.length) {
            var character = text.charAt(position++);
            if (character === '"') return result;
            if (character.charCodeAt(0) < 32) fail("Control character in JSON string.");
            if (character === "\\") {
                character = text.charAt(position++);
                var escapes = { '"': '"', "\\": "\\", "/": "/", b: "\b", f: "\f", n: "\n", r: "\r", t: "\t" };
                if (character === "u") {
                    var digits = text.substr(position, 4);
                    if (!/^[0-9a-fA-F]{4}$/.test(digits)) fail("Invalid Unicode escape in JSON.");
                    character = String.fromCharCode(parseInt(digits, 16)); position += 4;
                } else if (Object.prototype.hasOwnProperty.call(escapes, character)) character = escapes[character];
                else fail("Invalid JSON escape.");
            }
            result += character;
        }
        fail("Unterminated JSON string.");
    }
    function value(depth) {
        if (depth > 100) fail("JSON nesting is too deep.");
        space(); var character = text.charAt(position), result, key;
        if (character === '"') return string();
        if (character === "{" || character === "[") {
            var object = character === "{", end = object ? "}" : "]";
            result = object ? {} : []; position++; space();
            if (text.charAt(position) === end) { position++; return result; }
            while (true) {
                space();
                if (object) { key = string(); space(); if (text.charAt(position++) !== ":") fail("Missing JSON colon."); result[key] = value(depth + 1); }
                else result.push(value(depth + 1));
                space(); character = text.charAt(position++);
                if (character === end) return result;
                if (character !== ",") fail("Missing JSON comma.");
            }
        }
        var match = /^(true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)/.exec(text.substr(position));
        if (!match) fail("Invalid JSON value.");
        position += match[0].length;
        if (match[0] === "true") return true;
        if (match[0] === "false") return false;
        if (match[0] === "null") return null;
        return Number(match[0]);
    }
    var result = value(0); space(); if (position !== text.length) fail("Trailing content in JSON.");
    return result;
}
function quote(text) {
    return '"' + String(text).replace(/["\\\x00-\x1f]/g, function(character) {
        var escapes = { '"': '\\"', "\\": "\\\\", "\b": "\\b", "\f": "\\f", "\n": "\\n", "\r": "\\r", "\t": "\\t" };
        if (Object.prototype.hasOwnProperty.call(escapes, character)) return escapes[character];
        return "\\u" + ("0000" + character.charCodeAt(0).toString(16)).slice(-4);
    }) + '"';
}
function stringify(value, depth) {
    if (value === null) return "null";
    if (typeof value === "string") return quote(value);
    if (typeof value === "boolean" || typeof value === "number") return String(value);
    var parts = [], key;
    if (value instanceof Array) {
        for (var i = 0; i < value.length; i++) parts.push(stringify(value[i], depth + 1));
        return "[" + parts.join(", ") + "]";
    }
    for (key in value) if (Object.prototype.hasOwnProperty.call(value, key)) parts.push("  " + quote(key) + ": " + stringify(value[key], depth + 1));
    return "{\r\n" + parts.join(",\r\n") + "\r\n}";
}
function loadJson(path) { return parseJson(readUtf8(path)); }
function processAlive(pid) {
    return new Enumerator(GetObject("winmgmts:\\\\.\\root\\cimv2").ExecQuery("SELECT ProcessId FROM Win32_Process WHERE ProcessId=" + pid)).atEnd() === false;
}
function stopGame() {
    if (gamePid === null) return;
    if (processAlive(gamePid)) {
        command("taskkill.exe", ["/PID", String(gamePid), "/T"], true);
        var deadline = new Date().getTime() + 1000;
        while (processAlive(gamePid) && new Date().getTime() < deadline) WScript.Sleep(100);
        if (processAlive(gamePid)) command("taskkill.exe", ["/PID", String(gamePid), "/T", "/F"], true);
    }
    gamePid = null;
}
function globMatch(path, pattern) {
    var expression = "^";
    for (var i = 0; i < pattern.length; i++) {
        var character = pattern.charAt(i);
        if (character === "*") expression += ".*";
        else if (character === "?") expression += ".";
        else if (/^[\\.^$+(){}|]$/.test(character)) expression += "\\" + character;
        else expression += character;
    }
    return new RegExp(expression + "$", "i").test(path);
}
try {
    for (var argumentIndex = 0; argumentIndex < WScript.Arguments.length; argumentIndex++) {
        var argument = WScript.Arguments.Item(argumentIndex).toLowerCase();
        if (argument === "--working-tree" || argument === "-workingtree") workingTree = true;
        else if (argument === "--runtime" || argument === "-runtime") runtime = true;
        else if (argument === "--help" || argument === "-h") { echo("Usage: tools\\release_check.bat [--working-tree] [--runtime]"); WScript.Quit(0); }
        else fail("Unknown argument: " + argument);
    }
    var compilerVersion = trim(command("odin", ["version"]).output);
    var sourceCommit = trim(command("git", ["-C", repositoryRoot, "rev-parse", "HEAD"]).output);
    workspace = join(repositoryRoot, "build\\release check " + filesystem.GetTempName().replace(/\./g, "-"));
    var exportRoot = join(workspace, "Rune Engine"), gameRoot = join(workspace, "New Game");
    mkdir(exportRoot);
    if (workingTree) {
        echo("Warning: Testing the working copy, including uncommitted files. This is not proof of the published commit.");
        var files = command("git", ["-C", repositoryRoot, "ls-files", "--cached", "--others", "--exclude-standard", "-z"]).output.split("\x00"), copied = {};
        for (var fileIndex = 0; fileIndex < files.length; fileIndex++) {
            var relativePath = files[fileIndex];
            if (!relativePath || copied["$" + relativePath]) continue;
            copied["$" + relativePath] = true;
            var source = join(repositoryRoot, relativePath), destination = join(exportRoot, relativePath);
            if (!filesystem.FileExists(source)) continue;
            mkdir(filesystem.GetParentFolderName(destination)); filesystem.CopyFile(source, destination, true);
        }
    } else {
        var archive = join(workspace, "engine.tar");
        command("git", ["-C", repositoryRoot, "archive", "--format=tar", "--output=" + archive, sourceCommit]);
        command("tar.exe", ["-xf", archive, "-C", exportRoot]);
    }
    var submodule = "third_party/r3d-odin", dependencyRoot = join(repositoryRoot, submodule);
    if (!filesystem.FileExists(join(dependencyRoot, "r3d/r3d_core.odin"))) fail("Initialize dependencies with git submodule update --init --recursive.");
    var dependencyCommit = trim(workingTree ? command("git", ["-C", dependencyRoot, "rev-parse", "HEAD"]).output : command("git", ["-C", repositoryRoot, "rev-parse", sourceCommit + ":" + submodule]).output);
    if (workingTree) command(join(repositoryRoot, "tools/prepare_r3d.bat"), ["--check"]);
    var dependencyArchive = join(workspace, "r3d.tar");
    command("git", ["-C", dependencyRoot, "-c", "core.autocrlf=false", "archive", "--format=tar", "--output=" + dependencyArchive, dependencyCommit]);
    mkdir(join(exportRoot, submodule)); command("tar.exe", ["-xf", dependencyArchive, "-C", join(exportRoot, submodule)]);
    var requiredFiles = ["toolchain.json", "tools/new_project.bat", "tools/validate.bat", "tools/console.bat", "tools/prepare_r3d.bat", "third_party/r3d-compat/bindings.patch", "third_party/r3d-compat/files.blobs", "third_party/r3d-importer/sources.json", "templates/blank_project/build.bat", "docs/asset_credits.json"];
    for (var requiredIndex = 0; requiredIndex < requiredFiles.length; requiredIndex++) {
        if (!filesystem.FileExists(join(exportRoot, requiredFiles[requiredIndex]))) fail("The exported commit is missing " + requiredFiles[requiredIndex] + ". Commit the release tooling, or use --working-tree to test it first.");
    }
    echo(command(join(exportRoot, "tools/prepare_r3d.bat"), []).output);
    var toolchain = loadJson(join(exportRoot, "toolchain.json"));
    if (typeof toolchain.odin_release !== "string" || compilerVersion.indexOf(toolchain.odin_release) < 0) fail("Expected Odin " + toolchain.odin_release + "; found " + compilerVersion);
    if (compilerVersion.indexOf(toolchain.tested_odin_version) < 0) echo("Warning: Compiler differs from the recorded tested revision: " + toolchain.tested_odin_version);
    echo("Validating the exported engine and all examples...");
    var validationArguments = ["--all-examples"]; if (runtime) validationArguments.push("--runtime");
    echo(command(join(exportRoot, "tools/validate.bat"), validationArguments).output);
    echo(command(join(exportRoot, "tools/new_project.bat"), ["--path", gameRoot, "--name", "Release Check Game"]).output);
    echo(command(join(gameRoot, "build.bat"), ["--rune-root", exportRoot]).output);
    echo(command(join(gameRoot, "build.bat"), ["--rune-root", exportRoot, "--release"]).output);
    echo(command(join(exportRoot, "build/project_validator.exe"), [join(gameRoot, "project.json")]).output);
    var generatedFiles = ["project.json", "scenes/main.scene.json", "input/default.input.json"];
    for (var generatedIndex = 0; generatedIndex < generatedFiles.length; generatedIndex++) {
        var generatedFile = join(gameRoot, generatedFiles[generatedIndex]), schema = loadJson(generatedFile).$schema;
        if (typeof schema !== "string" || !filesystem.FileExists(join(filesystem.GetParentFolderName(generatedFile), schema))) fail("Generated schema reference does not resolve: " + generatedFiles[generatedIndex]);
    }
    var runtimePassed = false;
    if (runtime) {
        environment("RUNE_RELEASE_GAME") = join(gameRoot, "build/game.exe");
        environment("RUNE_RELEASE_STDOUT") = join(workspace, "game.stdout.log");
        environment("RUNE_RELEASE_STDERR") = join(workspace, "game.stderr.log");
        var service = GetObject("winmgmts:\\\\.\\root\\cimv2"), startup = service.Get("Win32_ProcessStartup").SpawnInstance_(); startup.ShowWindow = 0;
        // WMI creates the child through its service. Explicitly supply the
        // caller environment so our per-run paths and compiler PATH survive.
        var variables = new ActiveXObject("Scripting.Dictionary"), variableEnumerator = new Enumerator(environment), variableIndex = 0;
        for (; !variableEnumerator.atEnd(); variableEnumerator.moveNext()) variables.Add(variableIndex++, String(variableEnumerator.item()));
        startup.EnvironmentVariables = variables.Items();
        var processClass = service.Get("Win32_Process"), create = processClass.Methods_.Item("Create").InParameters.SpawnInstance_();
        create.CommandLine = 'cmd.exe /d /v:off /s /c ""%RUNE_RELEASE_GAME%" --console-dir=build/console >"%RUNE_RELEASE_STDOUT%" 2>"%RUNE_RELEASE_STDERR%""';
        create.CurrentDirectory = gameRoot; create.ProcessStartupInformation = startup;
        var started = processClass.ExecMethod_("Create", create);
        if (started.ReturnValue !== 0) fail("Could not launch the new game: Windows error " + started.ReturnValue);
        gamePid = started.ProcessId;
        var inbox = join(gameRoot, "build/console"), deadline = new Date().getTime() + 15000;
        while (!filesystem.FolderExists(inbox)) {
            if (!processAlive(gamePid) || new Date().getTime() >= deadline) fail("New project failed to start. See game.stdout.log and game.stderr.log in the release workspace.");
            WScript.Sleep(100);
        }
        var consoleCommands = ["status", "pause", "step 2", "capture build/first-frame.png"];
        for (var consoleIndex = 0; consoleIndex < consoleCommands.length; consoleIndex++) {
            var reply = parseJson(command(join(exportRoot, "tools/console.bat"), ["--directory", inbox, "--command", consoleCommands[consoleIndex], "--json"]).output);
            if (reply.ok !== true) fail("Console command failed: " + consoleCommands[consoleIndex]);
            if (consoleIndex === 0 && (!reply.data || !(reply.data.recent_errors instanceof Array) || reply.data.recent_errors.length)) fail("New project reported runtime errors.");
            if (consoleIndex === 3 && (!reply.data || !filesystem.FileExists(reply.data.path))) fail("New project capture failed.");
        }
        runtimePassed = true; stopGame();
    }
    var credits = loadJson(join(exportRoot, "docs/asset_credits.json")), pendingCredits = [], uncoveredAssets = [];
    if (!(credits.groups instanceof Array)) fail("Credits have no groups array.");
    for (var groupIndex = 0; groupIndex < credits.groups.length; groupIndex++) {
        var group = credits.groups[groupIndex];
        if (typeof group.name !== "string" || !(group.paths instanceof Array)) fail("Malformed asset credit group.");
        if (group.status !== "documented") pendingCredits.push(group.name);
    }
    function inspectAssets(directory) {
        var folder = filesystem.GetFolder(directory), fileEnumerator = new Enumerator(folder.Files);
        for (; !fileEnumerator.atEnd(); fileEnumerator.moveNext()) {
            var asset = fileEnumerator.item();
            if (!/^(png|jpg|jpeg|ttf|wav|mp3|ogg|obj|mtl|glb|gltf|hdr|fnt)$/i.test(filesystem.GetExtensionName(asset.Name))) continue;
            var path = asset.Path.substr(exportRoot.length + 1).replace(/\\/g, "/"), covered = false;
            for (var index = 0; index < credits.groups.length; index++) {
                var paths = credits.groups[index].paths;
                for (var patternIndex = 0; patternIndex < paths.length; patternIndex++) if (globMatch(path, paths[patternIndex])) covered = true;
            }
            if (!covered) uncoveredAssets.push(path);
        }
        var directories = new Enumerator(folder.SubFolders);
        for (; !directories.atEnd(); directories.moveNext()) inspectAssets(directories.item().Path);
    }
    inspectAssets(join(exportRoot, "examples")); uncoveredAssets.sort();
    var licensePresent = filesystem.FileExists(join(exportRoot, "LICENSE"));
    var operatingSystems = new Enumerator(GetObject("winmgmts:\\\\.\\root\\cimv2").ExecQuery("SELECT Caption, Version FROM Win32_OperatingSystem"));
    var operatingSystem = operatingSystems.item();
    var report = {
        source_commit: sourceCommit, source_mode: workingTree ? "working-tree" : "committed", dependency_commit: dependencyCommit,
        compiler: compilerVersion, platform: operatingSystem.Caption + " " + operatingSystem.Version,
        architecture: environment("PROCESSOR_ARCHITEW6432") || environment("PROCESSOR_ARCHITECTURE"),
        shell: "cmd.exe; Windows Script Host " + WScript.Version, display: null, engineering_passed: true, runtime_checked: runtimePassed,
        engine_license_present: licensePresent, asset_credit_groups_pending: pendingCredits, assets_without_credit_entry: uncoveredAssets,
        export_directory: exportRoot, project_directory: gameRoot
    };
    var reportPath = join(workspace, "report.json"); writeUtf8(reportPath, stringify(report, 0) + "\r\n");
    echo("Engineering checks passed. Report: " + reportPath);
    if (!licensePresent || pendingCredits.length || uncoveredAssets.length) echo("Warning: Publication prerequisites remain: engine licensing and/or asset credits. See docs/release.md.");
} catch (error) {
    writeLine(WScript.StdErr, "Release check failed: " + (error.message || String(error)));
    if (workspace) writeLine(WScript.StdErr, "Export and logs: " + workspace);
    try { stopGame(); } catch (cleanupError) { writeLine(WScript.StdErr, "Could not stop the game: " + cleanupError.message); }
    WScript.Quit(1);
}
