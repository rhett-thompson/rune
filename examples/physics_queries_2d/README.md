# Physics Queries 2D

Read contact events, collect sensor pickups, and visualize ray and circle queries after physics runs.

**Controls:** A/D moves. Gold boxes are pickups; blue boxes are walls. The ray points right and the circle marks the overlap query.

**Try editing:** [main.odin](main.odin): control and after_physics. [scenes/main.scene.json](scenes/main.scene.json): sensors and walls. Use the developer console's reload command to restore collected pickups.

Run from the repository root on Windows:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = '.exe'
odin run examples/physics_queries_2d -linker:msvc -collection:rune=rune "-out:build/physics_queries_2d$exe"
```

[All examples](../README.md)
