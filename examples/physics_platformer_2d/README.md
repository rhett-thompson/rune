# Physics Platformer 2D

Drive a platformer character with a rigid body and collision checks.

**Controls:** A/D moves; Space jumps.

**Try editing:** [main.odin](main.odin): movement, jumping, and grounding. [scenes/main.scene.json](scenes/main.scene.json): bodies, platforms, and colliders.

Run from the repository root with PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/physics_platformer_2d -collection:rune=rune "-out:build/physics_platformer_2d$exe"
```

[All examples](../README.md)
