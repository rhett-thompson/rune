# Camera Switching

Choose the active scene camera at runtime.

**Controls:** 1, 2, and 3 select cameras.

**Try editing:** [scenes/main.scene.json](scenes/main.scene.json): camera positions and projections. [main.odin](main.odin): camera selection.

Run from the repository root with PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/camera_switching -collection:rune=rune -collection:r3d=third_party/r3d-odin "-out:build/camera_switching$exe"
```

[All examples](../README.md)
