# Physics Platformer 2D

Drive a capsule character with Rune's built-in `CharacterController2D`, backed by a rigid body. Platforms and circles use scene-authored `ShapeRenderer2D` components.

**Controls:** A/D moves; Space jumps.

**Try editing:** [main.odin](main.odin): submit mapped movement and jump requests. [scenes/main.scene.json](scenes/main.scene.json): motor tuning, bodies, shapes, and colliders. `jump_speed` is 600 for the previous 150-unit jump setting at gravity 1200; the capsule keeps the old collider bounds with rounded corners.

Run from the repository root with PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/physics_platformer_2d -collection:rune=rune "-out:build/physics_platformer_2d$exe"
```

[All examples](../README.md)
