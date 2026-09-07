# Box3D Ball Drop

Simulate spheres and boxes with Box3D and draw their shapes directly through raylib.

**Controls:** R reloads the scene and resets the bodies.

**Try editing:** [scenes/main.scene.json](scenes/main.scene.json): body and collider settings. [main.odin](main.odin): shape rendering and native body rotation access.

Run from the repository root with PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/box3d_balls -collection:rune=rune "-out:build/box3d_balls$exe"
```

[All examples](../README.md)
