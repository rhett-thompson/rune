# Third Person 3D

Move a character relative to the camera and update a following camera in Odin.

**Controls:** WASD moves; Space jumps; wheel zooms. Left-drag orbits; right-drag also turns the character.

**Try editing:** [main.odin](main.odin): movement basis, follow distance, and orbit limits. [scenes/main.scene.json](scenes/main.scene.json): player and obstacles.

Run from the repository root with PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/third_person_3d -collection:rune=rune -collection:r3d=third_party/r3d-odin "-out:build/third_person_3d$exe"
```

[All examples](../README.md)
