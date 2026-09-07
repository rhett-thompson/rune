# First Person 3D

Connect first-person input to a character controller and scene collision.

**Controls:** WASD moves; mouse looks; Space jumps; Left Shift sprints; Escape toggles the cursor.

**Try editing:** [controller.odin](controller.odin): movement and looking. [scenes/main.scene.json](scenes/main.scene.json): player settings and obstacles. [input/default.input.json](input/default.input.json): controls.

Run from the repository root with PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/first_person_3d -collection:rune=rune -collection:r3d=third_party/r3d-odin "-out:build/first_person_3d$exe"
```

[All examples](../README.md)
