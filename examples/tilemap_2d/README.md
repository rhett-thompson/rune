# Tilemap 2D

Move an animated knight through a tilemap with collision and camera following.

**Controls:** WASD moves the knight.

**Try editing:** [assets/world.tileset.json](assets/world.tileset.json): tile definitions. [scenes/main.scene.json](scenes/main.scene.json): map layers and player settings. [main.odin](main.odin): movement and animation selection.

Run from the repository root on Windows:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = '.exe'
odin run examples/tilemap_2d -linker:msvc -collection:rune=rune "-out:build/tilemap_2d$exe"
```

[All examples](../README.md)
