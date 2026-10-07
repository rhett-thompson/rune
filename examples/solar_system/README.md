# Solar System

Animate a small solar system with Orbit and Rotator components.

**Controls:** No movement controls.

**Try editing:** [scenes/main.scene.json](scenes/main.scene.json): hierarchy, orbit radii, and speeds. [main.odin](main.odin): orbit and rotation updates.

Run from the repository root on Windows:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = '.exe'
odin run examples/solar_system -collection:rune=rune -linker:msvc -collection:r3d=third_party/r3d-odin "-out:build/solar_system$exe"
```

[All examples](../README.md)
