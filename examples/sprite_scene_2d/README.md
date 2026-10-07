# Sprite Scene 2D

Load a sprite and camera using only built-in components. The entry point needs no custom systems.

**Controls:** No movement controls. Edit the scene while it runs.

**Try editing:** [scenes/main.scene.json](scenes/main.scene.json): move or scale the skeleton, change its texture, or adjust Camera2D.zoom. [main.odin](main.odin): the complete startup code.

Run from the repository root on Windows:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = '.exe'
odin run examples/sprite_scene_2d -linker:msvc -collection:rune=rune "-out:build/sprite_scene_2d$exe"
```

[All examples](../README.md)
