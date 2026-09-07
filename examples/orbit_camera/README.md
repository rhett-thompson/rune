# Orbit Camera

Use a scene OrbitCamera3D component with mapped mouse input.

**Controls:** The camera orbits automatically; left-drag takes manual control.

**Try editing:** [scenes/main.scene.json](scenes/main.scene.json): target and orbit settings. [input/default.input.json](input/default.input.json): mouse axes. [main.odin](main.odin): camera update.

Run from the repository root with PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/orbit_camera -collection:rune=rune -collection:r3d=third_party/r3d-odin "-out:build/orbit_camera$exe"
```

[All examples](../README.md)
