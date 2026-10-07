@if (@X)==(@Y) @end /*
@echo off
setlocal EnableExtensions DisableDelayedExpansion
cscript //nologo //E:JScript "%~f0" %*
exit /b %errorlevel%
*/
// Rebuild the demo's original hand-authored walkable center surface.
try {
    if (WScript.Arguments.length) {
        if (WScript.Arguments(0) == "--help" || WScript.Arguments(0) == "-h") { WScript.Echo("Usage: examples\\navigation_3d\\generate_mesh.bat"); WScript.Quit(0); }
        throw new Error("This generator takes no arguments.");
    }
    var vertices = [], triangles = [], lookup = {};
    function vertex(x, y, z) {
        var key = x + "," + y + "," + z;
        if (lookup[key] === undefined) { lookup[key] = vertices.length; vertices.push("[" + x + ", " + y + ", " + z + "]"); }
        return lookup[key];
    }
    function quad(x0, x1, z0, z1, y0, y1) {
        var a = vertex(x0,y0,z0), b = vertex(x1,y1,z0), c = vertex(x1,y1,z1), d = vertex(x0,y0,z1);
        triangles.push("[" + a + ", " + b + ", " + c + "]", "[" + a + ", " + c + ", " + d + "]");
    }
    for (var x = -8; x <= -4; x += 2) for (var z = -4; z <= 2; z += 2) if (x != -6 || z != -2) quad(x,x+2,z,z+2,0,0);
    for (var x = -2; x <= 0; x += 2) for (var z = -2; z <= 0; z += 2) quad(x,x+2,z,z+2,(x+2)/2,(x+4)/2);
    for (var x = 2; x <= 6; x += 2) for (var z = -4; z <= 2; z += 2) quad(x,x+2,z,z+2,2,2);
    quad(10,12,0,2,0,0);
    var text = '{\n  "$schema": "../../schemas/navmesh.schema.json",\n  "version": 1,\n  "agent_radius": 0.4,\n  "agent_height": 2,\n  "vertices": [\n    ' + vertices.join(",\n    ") + '\n  ],\n  "triangles": [\n    ' + triangles.join(",\n    ") + '\n  ]\n}\n';
    var fs = new ActiveXObject("Scripting.FileSystemObject");
    var file = fs.CreateTextFile(fs.BuildPath(fs.GetParentFolderName(WScript.ScriptFullName), "course.navmesh.json"), true, false);
    file.Write(text); file.Close();
    WScript.Echo("Wrote " + vertices.length + " vertices and " + triangles.length + " triangles.");
} catch (error) { WScript.StdErr.WriteLine("Error: " + error.message); WScript.Quit(1); }
