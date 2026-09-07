# Hello 3D

Render a basic 3D scene through the R3D bridge and rotate its cube in an update callback.

**Controls:** No movement controls.

**Try editing:** [scenes/main.scene.json](scenes/main.scene.json): cube and camera. [main.odin](main.odin): bridge lifetime and rotation speeds.

Run from the repository root with PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/hello_3d -collection:rune=rune -collection:r3d=third_party/r3d-odin "-out:build/hello_3d$exe"
```

[All examples](../README.md)
