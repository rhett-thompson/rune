@if (@X)==(@Y) @end /*
@echo off
setlocal EnableExtensions DisableDelayedExpansion
cscript //nologo //E:JScript "%~f0" %*
exit /b %errorlevel%
*/
// Generates the original two-joint model using Windows' built-in JScript host.
try {
    if (WScript.Arguments.length) {
        if (WScript.Arguments(0) == "--help" || WScript.Arguments(0) == "-h") { WScript.Echo("Usage: examples\\skeletal_animation_3d\\generate_fixture.bat"); WScript.Quit(0); }
        throw new Error("This generator takes no arguments.");
    }
    function json(value) {
        if (value === null) return "null";
        if (typeof value == "string") return '"' + value.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\r/g, "\\r").replace(/\n/g, "\\n") + '"';
        if (typeof value != "object") return String(value);
        var items = [];
        if (value instanceof Array) { for (var i = 0; i < value.length; ++i) items.push(json(value[i])); return "[" + items.join(",") + "]"; }
        for (var key in value) if (value.hasOwnProperty(key)) items.push(json(key) + ":" + json(value[key]));
        return "{" + items.join(",") + "}";
    }
    var bytes = [], views = [], accessors = [];
    function integer(value, size) { for (var i = 0; i < size; ++i) { bytes.push(value % 256); value = Math.floor(value / 256); } }
    function float32(value) {
        var sign = value < 0 || value === 0 && 1 / value < 0 ? 2147483648 : 0;
        value = Math.abs(value);
        if (!value) { integer(sign, 4); return; }
        var exponent = Math.floor(Math.log(value) / Math.LN2);
        var mantissa = Math.round(value / Math.pow(2, exponent) * 8388608) - 8388608;
        if (mantissa == 8388608) { ++exponent; mantissa = 0; }
        integer(sign + (exponent + 127) * 8388608 + mantissa, 4);
    }
    function accessor(values, type, components, componentType, minimum, maximum) {
        componentType = componentType || 5126;
        while (bytes.length % 4) bytes.push(0);
        var offset = bytes.length;
        for (var i = 0; i < values.length; ++i) { if (componentType == 5123) integer(values[i], 2); else float32(values[i]); }
        var item = {bufferView: views.length, componentType: componentType, count: values.length / components, type: type};
        if (minimum) { item.min = minimum; item.max = maximum; }
        views.push({buffer: 0, byteOffset: offset, byteLength: bytes.length - offset});
        accessors.push(item); return accessors.length - 1;
    }
    function base64(values) {
        var alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", text = "";
        for (var i = 0; i < values.length; i += 3) {
            var a = values[i], b = i + 1 < values.length ? values[i+1] : 0, c = i + 2 < values.length ? values[i+2] : 0;
            text += alphabet.charAt(a >> 2) + alphabet.charAt((a & 3) << 4 | b >> 4) + (i+1 < values.length ? alphabet.charAt((b & 15) << 2 | c >> 6) : "=") + (i+2 < values.length ? alphabet.charAt(c & 63) : "=");
        }
        return text;
    }
    var positions = [], normals = [], joints = [], weights = [], indices = [];
    var faces = [
        {n:[0,0,1],v:[[-1,0,1],[1,0,1],[1,1,1],[-1,1,1]]},
        {n:[0,0,-1],v:[[1,0,-1],[-1,0,-1],[-1,1,-1],[1,1,-1]]},
        {n:[1,0,0],v:[[1,0,1],[1,0,-1],[1,1,-1],[1,1,1]]},
        {n:[-1,0,0],v:[[-1,0,-1],[-1,0,1],[-1,1,1],[-1,1,-1]]},
        {n:[0,1,0],v:[[-1,1,1],[1,1,1],[1,1,-1],[-1,1,-1]]},
        {n:[0,-1,0],v:[[-1,0,-1],[1,0,-1],[1,0,1],[-1,0,1]]}
    ];
    for (var bone = 0; bone < 2; ++bone) for (var f = 0; f < faces.length; ++f) {
        var face = faces[f], base = positions.length / 3;
        for (var i = 0; i < face.v.length; ++i) {
            positions.push(face.v[i][0] * 0.18, face.v[i][1] + bone, face.v[i][2] * 0.18);
            normals.push(face.n[0],face.n[1],face.n[2]); joints.push(bone,0,0,0); weights.push(1,0,0,0);
        }
        indices.push(base,base+1,base+2,base,base+2,base+3);
    }
    var position = accessor(positions,"VEC3",3,5126,[-0.18,0,-0.18],[0.18,2,0.18]);
    var normal = accessor(normals,"VEC3",3), joint = accessor(joints,"VEC4",4,5123), weight = accessor(weights,"VEC4",4), index = accessor(indices,"SCALAR",1,5123);
    var inverseBinds = accessor([1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1,1,0,0,0,0,1,0,0,0,0,1,0,0,-1,0,1],"MAT4",16);
    var times = accessor([0,0.5,1,1.5,2],"SCALAR",1,5126,[0],[2]);
    function rotations(angles) { var values = []; for (var i = 0; i < angles.length; ++i) { var half = angles[i] * Math.PI / 360; values.push(0,0,Math.sin(half),Math.cos(half)); } return accessor(values,"VEC4",4); }
    var bend = rotations([0,75,0,-75,0]), sway = rotations([-25,0,25,0,-25]);
    var document = {
        asset:{version:"2.0",generator:"Rune two-joint fixture generator"},scene:0,scenes:[{nodes:[0,1]}],
        nodes:[{name:"Arm",mesh:0,skin:0},{name:"Root",children:[2]},{name:"Tip",translation:[0,1,0]}],
        skins:[{joints:[1,2],skeleton:1,inverseBindMatrices:inverseBinds}],
        meshes:[{primitives:[{attributes:{POSITION:position,NORMAL:normal,JOINTS_0:joint,WEIGHTS_0:weight},indices:index}]}],
        animations:[{name:"bend",samplers:[{input:times,output:bend,interpolation:"LINEAR"}],channels:[{sampler:0,target:{node:2,path:"rotation"}}]},
                    {name:"sway",samplers:[{input:times,output:sway,interpolation:"LINEAR"}],channels:[{sampler:0,target:{node:1,path:"rotation"}}]}],
        buffers:[{byteLength:bytes.length,uri:"data:application/octet-stream;base64,"+base64(bytes)}],bufferViews:views,accessors:accessors
    };
    var fs = new ActiveXObject("Scripting.FileSystemObject"), directory = fs.BuildPath(fs.GetParentFolderName(WScript.ScriptFullName),"assets");
    if (!fs.FolderExists(directory)) fs.CreateFolder(directory);
    var file = fs.CreateTextFile(fs.BuildPath(directory,"arm.gltf"),true,false); file.Write(json(document)+"\n"); file.Close();
    WScript.Echo("Wrote assets\\arm.gltf (" + bytes.length + " binary bytes, two joints, two clips).");
} catch (error) { WScript.StdErr.WriteLine("Error: " + error.message); WScript.Quit(1); }
