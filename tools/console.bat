@if (@X)==(@Y) @end /*
@echo off
setlocal EnableExtensions DisableDelayedExpansion
set RUNE_CONSOLE_ARGUMENTS=%*
cscript //nologo //E:JScript "%~f0"
exit /b %errorlevel%
*/
// The Windows script host is built in. No commands or JSON are evaluated.
var fs = new ActiveXObject("Scripting.FileSystemObject");
function fail(message) { throw new Error(message); }
// cscript removes doubled quotes while parsing its argv. Preserve CMD's raw
// arguments in the wrapper, then decode doubled quotes inside quoted values.
function arguments() {
    var raw = new ActiveXObject("WScript.Shell").Environment("PROCESS")("RUNE_CONSOLE_ARGUMENTS");
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
    if (quoted) fail("Unterminated argument quote. Inside a quoted argument, use doubled quotes for literal JSON quotes.");
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
function utf8Length(text) {
    var stream = new ActiveXObject("ADODB.Stream");
    stream.Type = 2; stream.Charset = "utf-8"; stream.Open(); stream.WriteText(text);
    var count = stream.Size - 3; stream.Close(); return count;
}
function parseJSON(text) {
    var at = 0, depth = 0;
    function ws() { while (/\s/.test(text.charAt(at)) && at < text.length) at++; }
    function string() {
        var result = ""; at++;
        while (at < text.length) {
            var c = text.charAt(at++);
            if (c === '"') return result;
            if (c.charCodeAt(0) < 32) fail("Invalid JSON string.");
            if (c === "\\") {
                c = text.charAt(at++);
                var escapes = {'"':'"', '\\':'\\', '/':'/', b:'\b', f:'\f', n:'\n', r:'\r', t:'\t'};
                if (c === "u") {
                    var digits = text.substr(at, 4);
                    if (!/^[0-9a-fA-F]{4}$/.test(digits)) fail("Invalid JSON unicode escape.");
                    result += String.fromCharCode(parseInt(digits,16)); at += 4;
                } else {
                    if (!Object.prototype.hasOwnProperty.call(escapes,c)) fail("Invalid JSON escape.");
                    result += escapes[c];
                }
            } else result += c;
        }
        fail("Unterminated JSON string.");
    }
    function value() {
        ws(); if (++depth > 128) fail("JSON nesting exceeds 128 levels.");
        var c = text.charAt(at), result, match;
        if (c === '"') result = string();
        else if (c === "{" || c === "[") {
            var array = c === "[", end = array ? "]" : "}"; result = array ? [] : {}; at++; ws();
            if (text.charAt(at) !== end) {
                while (true) {
                    var key;
                    if (!array) {
                        if (text.charAt(at) !== '"') fail("Expected JSON property.");
                        key = string(); ws(); if (text.charAt(at++) !== ":") fail("Expected JSON colon.");
                    }
                    var child = value(); if (array) result.push(child); else result[key] = child;
                    ws(); if (text.charAt(at) === end) break;
                    if (text.charAt(at++) !== ",") fail("Expected JSON comma."); ws();
                }
            }
            at++;
        } else if (text.substr(at,4) === "true") { result = true; at += 4; }
        else if (text.substr(at,5) === "false") { result = false; at += 5; }
        else if (text.substr(at,4) === "null") { result = null; at += 4; }
        else {
            match = /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/.exec(text.substr(at));
            if (!match) fail("Invalid JSON value."); result = Number(match[0]); at += match[0].length;
        }
        depth--; return result;
    }
    var result = value(); ws(); if (at !== text.length) fail("Unexpected data after JSON."); return result;
}
function stringify(value) {
    if (value === null) return "null";
    if (typeof value === "string") return '"' + value.replace(/[\\"\x00-\x1f\x7f-\uffff]/g, function(c) {
        if (c === '"' || c === '\\') return '\\' + c;
        return '\\u' + ('0000' + c.charCodeAt(0).toString(16)).slice(-4);
    }) + '"';
    if (typeof value !== "object") return String(value);
    var parts = [], array = value instanceof Array;
    if (array) { for (var i = 0; i < value.length; i++) parts.push(stringify(value[i])); }
    else { for (var key in value) if (Object.prototype.hasOwnProperty.call(value,key)) parts.push(stringify(key) + ":" + stringify(value[key])); }
    return (array ? "[" : "{") + parts.join(",") + (array ? "]" : "}");
}
var staging = "", request = "", reply = "", resultCode = 0;
try {
    var args = arguments(), command = null, directory = "", json = false, timeout = 10;
    for (var i = 0; i < args.length; i++) {
        var key = args[i].toLowerCase();
        if (key === "--help" || key === "-h") { WScript.Echo('Usage: tools\\console.bat --directory INBOX --command "COMMAND" [--json] [--timeout-seconds 10]'); WScript.Quit(0); }
        if (key === "--json" || key === "-json") { json = true; continue; }
        if (key !== "--command" && key !== "-command" && key !== "--directory" && key !== "-directory" && key !== "--timeout-seconds" && key !== "-timeoutseconds") fail("Unknown argument: " + args[i]);
        if (++i >= args.length) fail("Missing value for " + key);
        if (key === "--command" || key === "-command") command = args[i];
        else if (key === "--directory" || key === "-directory") directory = args[i];
        else { if (!/^[0-9]+$/.test(args[i])) fail("Timeout must be an integer from 1 to 300."); timeout = Number(args[i]); }
    }
    if (!directory || command === null) fail("Pass --directory INBOX and --command COMMAND.");
    if (timeout < 1 || timeout > 300) fail("Timeout must be an integer from 1 to 300.");
    if (/[\r\n\x00]/.test(command) || utf8Length(command) > 256) fail("Send one command of at most 256 UTF-8 bytes.");
    directory = fs.GetAbsolutePathName(directory);
    if (!fs.FolderExists(directory)) fail("Console directory does not exist: " + directory);
    var id = "rune-" + (new Date()).getTime().toString(16) + "-" + fs.GetTempName().replace(/\./g,"-");
    staging = fs.BuildPath(directory,id + ".tmp"); request = fs.BuildPath(directory,id + ".cmd"); reply = fs.BuildPath(directory,id + ".result.json");
    writeUTF8(staging,command);
    var publishDeadline = (new Date()).getTime() + 2000;
    while (true) {
        try { fs.MoveFile(staging,request); break; }
        catch (error) {
            if (!fs.FileExists(staging) || fs.FileExists(request) || (new Date()).getTime() >= publishDeadline) throw error;
            WScript.Sleep(25);
        }
    }
    var deadline = (new Date()).getTime() + timeout * 1000;
    while (!fs.FileExists(reply)) {
        if ((new Date()).getTime() >= deadline) fail("Console timed out. A claimed command may still finish; check the result before retrying.");
        WScript.Sleep(100);
    }
    var result = parseJSON(readUTF8(reply));
    if (!result || typeof result.ok !== "boolean" || !(result.lines instanceof Array)) fail("Invalid console reply: expected ok and lines.");
    if (json) writeLine(WScript.StdOut,stringify(result));
    else {
        for (var j = 0; j < result.lines.length; j++) writeLine(WScript.StdOut,String(result.lines[j]));
        if (result.data !== null && typeof result.data !== "undefined") writeLine(WScript.StdOut,stringify(result.data));
    }
    if (!result.ok) fail("Console command failed: " + command + "\n" + result.lines.join("\n"));
} catch (error) { resultCode = 1; writeLine(WScript.StdErr,error.message || String(error)); }
finally {
    var paths = [staging,request,reply];
    for (var k = 0; k < paths.length; k++) if (paths[k] && fs.FileExists(paths[k])) {
        try { fs.DeleteFile(paths[k]); } catch (error) { resultCode = 1; writeLine(WScript.StdErr,"Could not remove console file: " + paths[k]); }
    }
}
WScript.Quit(resultCode);
