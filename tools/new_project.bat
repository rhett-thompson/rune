@if (@X)==(@Y) @end /*
@echo off
setlocal EnableExtensions DisableDelayedExpansion
set RUNE_NEW_PROJECT_ARGUMENTS=%*
cscript //nologo //E:JScript "%~f0"
exit /b %errorlevel%
*/
// Windows ships this script host. JSON is edited as data, never evaluated.
var fs = new ActiveXObject("Scripting.FileSystemObject");
function fail(message) { throw new Error(message); }
// cscript removes doubled quotes while parsing its argv. Preserve CMD's raw
// arguments in the wrapper, then decode doubled quotes inside quoted values.
function arguments() {
    var raw = new ActiveXObject("WScript.Shell").Environment("PROCESS")("RUNE_NEW_PROJECT_ARGUMENTS");
    var result = [], token = "", quoted = false, started = false;
    for (var i = 0; i < raw.length; ++i) {
        var c = raw.charAt(i);
        if (c === '"') {
            if (quoted && raw.charAt(i+1) === '"') { token += '"'; ++i; }
            else quoted = !quoted;
            started = true;
        } else if (!quoted && /[ \t]/.test(c)) {
            if (started) { result.push(token); token = ""; started = false; }
        } else { token += c; started = true; }
    }
    if (quoted) fail("Unterminated argument quote. Inside a quoted argument, use doubled quotes for literal quotes.");
    if (started) result.push(token);
    return result;
}
function writeLine(stream, text) {
    try { stream.WriteLine(text); }
    catch (error) { stream.WriteLine(String(text).replace(/[^\x20-\x7e\r\n\t]/g, function(c) { return "\\u" + ("0000" + c.charCodeAt(0).toString(16)).slice(-4); })); }
}
function readUTF8(path) {
    var stream = new ActiveXObject("ADODB.Stream");
    stream.Type = 2; stream.Charset = "utf-8"; stream.Open(); stream.LoadFromFile(path);
    var text = stream.ReadText(); stream.Close(); return text;
}
function writeUTF8(path, text) {
    var stream = new ActiveXObject("ADODB.Stream");
    stream.Type = 2; stream.Charset = "utf-8"; stream.Open(); stream.WriteText(text);
    stream.Position = 0; stream.Type = 1; stream.Position = 3;
    var binary = new ActiveXObject("ADODB.Stream"); binary.Type = 1; binary.Open();
    stream.CopyTo(binary); binary.SaveToFile(path, 2); binary.Close(); stream.Close();
}
function quote(text) {
    return '"' + String(text).replace(/[\\"\x00-\x1f]/g, function(c) {
        if (c === '"' || c === '\\') return '\\' + c;
        return '\\u' + ('0000' + c.charCodeAt(0).toString(16)).slice(-4);
    }) + '"';
}
function mkdir(path) {
    if (fs.FolderExists(path)) return;
    var parent = fs.GetParentFolderName(path);
    if (parent && !fs.FolderExists(parent)) mkdir(parent);
    fs.CreateFolder(path);
}
try {
    var destination = "", name = "", args = arguments();
    for (var i = 0; i < args.length; i++) {
        var key = args[i].toLowerCase();
        if (key === "--help" || key === "-h") { WScript.Echo('Usage: tools\\new_project.bat --path DIRECTORY [--name NAME]'); WScript.Quit(0); }
        if (key !== "--path" && key !== "-path" && key !== "--name" && key !== "-name") fail("Unknown argument: " + args[i]);
        if (++i >= args.length) fail("Missing value for " + key);
        if (key === "--path" || key === "-path") destination = args[i]; else name = args[i];
    }
    if (!destination) fail("Pass --path DIRECTORY.");
    destination = fs.GetAbsolutePathName(destination);
    if (fs.FolderExists(destination) || fs.FileExists(destination)) fail("Destination already exists: " + destination);
    if (!name) name = fs.GetFileName(destination);
    if (!name.replace(/\s/g, "")) fail("The project needs a non-empty name.");
    var root = fs.GetParentFolderName(fs.GetParentFolderName(WScript.ScriptFullName));
    var template = fs.GetFolder(fs.BuildPath(root, "templates\\blank_project"));
    mkdir(fs.GetParentFolderName(destination)); fs.CreateFolder(destination);
    var entries = new Enumerator(template.Files);
    for (; !entries.atEnd(); entries.moveNext()) fs.CopyFile(entries.item().Path, fs.BuildPath(destination, entries.item().Name), false);
    entries = new Enumerator(template.SubFolders);
    for (; !entries.atEnd(); entries.moveNext()) {
        if (entries.item().Name !== "build") fs.CopyFolder(entries.item().Path, fs.BuildPath(destination, entries.item().Name), false);
    }
    fs.CopyFolder(fs.BuildPath(root, "schemas"), fs.BuildPath(destination, "schemas"), false);
    function rewrite(relative, schema, project) {
        var path = fs.BuildPath(destination, relative), text = readUTF8(path);
        var schemaPattern = /(^\s*"\$schema"\s*:\s*)"(?:[^"\\]|\\.)*"/m;
        if (!schemaPattern.test(text)) fail("Missing template schema: " + relative);
        text = text.replace(schemaPattern, function(all, prefix) { return prefix + quote(schema); });
        if (project) {
            text = text.replace(/(^\s*"(?:name|title)"\s*:\s*)"(?:[^"\\]|\\.)*"/gm, function(all, prefix) { return prefix + quote(name); });
        }
        writeUTF8(path, text);
    }
    rewrite("project.json", "schemas/project.schema.json", true);
    rewrite("scenes\\main.scene.json", "../schemas/scene.schema.json", false);
    rewrite("input\\default.input.json", "../schemas/input.schema.json", false);
    writeLine(WScript.StdOut,"Created " + destination);
    WScript.Echo("Run build.bat on Windows or sh build.sh on Linux with --rune-root pointing to the engine checkout.");
} catch (error) { writeLine(WScript.StdErr,error.message || String(error)); WScript.Quit(1); }
