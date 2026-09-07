# Physics Queries 2D

Read contact events, collect sensor pickups, and visualize ray and circle queries after physics runs.

**Controls:** A/D moves. Gold boxes are pickups; blue boxes are walls. The ray points right and the circle marks the overlap query.

**Try editing:** [main.odin](main.odin): control and after_physics. [scenes/main.scene.json](scenes/main.scene.json): sensors and walls. Use the developer console's reload command to restore collected pickups.

Run from the repository root with PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/physics_queries_2d -collection:rune=rune "-out:build/physics_queries_2d$exe"
```

[All examples](../README.md)
