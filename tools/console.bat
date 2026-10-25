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
function copyBytes(source, destination) {
    var stream = new ActiveXObject("ADODB.Stream");
    stream.Type = 1; stream.Open(); stream.LoadFromFile(source);
    // Unlike CopyFile, this does not copy the source file's read-only attribute.
    stream.SaveToFile(destination, 1); stream.Close();
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
function validateEntry(entry, batch) {
    if (!entry || typeof entry.ok !== "boolean" || !(entry.lines instanceof Array)) fail("Invalid console reply: expected ok and lines.");
    if (batch && (typeof entry.command !== "string" || !Object.prototype.hasOwnProperty.call(entry,"data"))) fail("Invalid console batch entry: expected command and data.");
    for (var i = 0; i < entry.lines.length; i++) if (typeof entry.lines[i] !== "string") fail("Invalid console reply: lines must contain strings.");
}
function printEntry(entry) {
    for (var i = 0; i < entry.lines.length; i++) writeLine(WScript.StdOut,entry.lines[i]);
    if (entry.data !== null && typeof entry.data !== "undefined") writeLine(WScript.StdOut,stringify(entry.data));
}
function count(value) { return typeof value === "number" && isFinite(value) && value >= 0 && value <= 4096 && Math.floor(value) === value; }
var staging = "", request = "", reply = "", resultCode = 0, replyConsumed = false;
try {
    var args = arguments(), command = null, batchFile = null, directory = "", json = false, timeout = null;
    for (var i = 0; i < args.length; i++) {
        var key = args[i].toLowerCase();
        if (key === "--help" || key === "-h") { WScript.Echo('Usage: tools\\console.bat --directory INBOX (--command "COMMAND" | --batch-file FILE) [--json] [--timeout-seconds 1..300]\nDefault timeout: command 10 seconds; batch 300 seconds.'); WScript.Quit(0); }
        if (key === "--json" || key === "-json") { json = true; continue; }
        if (key !== "--command" && key !== "-command" && key !== "--batch-file" && key !== "-batchfile" && key !== "--directory" && key !== "-directory" && key !== "--timeout-seconds" && key !== "-timeoutseconds") fail("Unknown argument: " + args[i]);
        if (++i >= args.length) fail("Missing value for " + key);
        if (key === "--command" || key === "-command") command = args[i];
        else if (key === "--batch-file" || key === "-batchfile") batchFile = args[i];
        else if (key === "--directory" || key === "-directory") directory = args[i];
        else { if (!/^[0-9]+$/.test(args[i])) fail("Timeout must be an integer from 1 to 300."); timeout = Number(args[i]); }
    }
    if (!directory || (command === null) === (batchFile === null)) fail("Pass --directory INBOX and exactly one of --command COMMAND or --batch-file FILE.");
    var batch = batchFile !== null;
    if (timeout === null) timeout = batch ? 300 : 10;
    if (timeout < 1 || timeout > 300) fail("Timeout must be an integer from 1 to 300.");
    if (batch) {
        batchFile = fs.GetAbsolutePathName(batchFile);
        if (!fs.FileExists(batchFile)) fail("Batch file does not exist: " + batchFile);
        if (fs.GetFile(batchFile).Size > 1048576) fail("Batch exceeds 1048576 bytes.");
    } else if (/[\r\n\x00]/.test(command) || utf8Length(command) > 256) fail("Send one command of at most 256 UTF-8 bytes.");
    directory = fs.GetAbsolutePathName(directory);
    if (!fs.FolderExists(directory)) fail("Console directory does not exist: " + directory);
    var id = "rune-" + (new Date()).getTime().toString(16) + "-" + fs.GetTempName().replace(/\./g,"-");
    staging = fs.BuildPath(directory,id + ".tmp"); request = fs.BuildPath(directory,id + (batch ? ".batch" : ".cmd")); reply = fs.BuildPath(directory,id + ".result.json");
    if (batch) {
        // Copy bytes unchanged, preserving UTF-8 and CRLF. The engine validates lines.
        copyBytes(batchFile,staging);
        if (fs.GetFile(staging).Size > 1048576) fail("Batch exceeds 1048576 bytes.");
    } else writeUTF8(staging,command);
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
        if ((new Date()).getTime() >= deadline) fail("Console timed out. A claimed request may still finish; timeout does not cancel it. Check the result before retrying: " + reply);
        WScript.Sleep(100);
    }
    var resultText = readUTF8(reply);
    replyConsumed = true;
    var result = parseJSON(resultText);
    if (batch) {
        if (!result || typeof result.ok !== "boolean" || typeof result.complete !== "boolean" || typeof result.error !== "string" || !(result.results instanceof Array) || !count(result.requested) || !count(result.completed)) fail("Invalid console batch reply: expected ok, complete, requested, completed, error, and results.");
        if (result.completed !== result.results.length || result.completed > result.requested || (result.complete && result.completed !== result.requested)) fail("Invalid console batch reply: inconsistent counts.");
        var allOk = true;
        for (var j = 0; j < result.results.length; j++) { validateEntry(result.results[j],true); allOk = allOk && result.results[j].ok; }
        if (result.ok !== (result.complete && allOk && result.error === "")) fail("Invalid console batch reply: inconsistent success state.");
    } else validateEntry(result,false);
    if (json) writeLine(WScript.StdOut,stringify(result));
    else if (batch) {
        for (var j = 0; j < result.results.length; j++) {
            writeLine(WScript.StdOut,"[" + (j+1) + "/" + result.requested + "] " + result.results[j].command);
            printEntry(result.results[j]);
        }
    } else printEntry(result);
    if (!result.ok) {
        if (batch) fail("Console batch failed or incomplete (" + result.completed + "/" + result.requested + " completed)." + (result.error ? " " + result.error : ""));
        fail("Console command failed: " + command + "\n" + result.lines.join("\n"));
    }
} catch (error) { resultCode = 1; writeLine(WScript.StdErr,error.message || String(error)); }
finally {
    // A timed-out request can still publish a reply during cleanup. Preserve it
    // for inspection unless this sender already read it.
    var paths = [staging,request];
    if (replyConsumed) paths.push(reply);
    for (var k = 0; k < paths.length; k++) if (paths[k] && fs.FileExists(paths[k])) {
        try { fs.DeleteFile(paths[k]); } catch (error) { resultCode = 1; writeLine(WScript.StdErr,"Could not remove console file: " + paths[k]); }
    }
}
WScript.Quit(resultCode);
