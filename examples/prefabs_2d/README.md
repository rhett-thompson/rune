# Prefabs 2D

Create entities from a shared prefab and override their values in a scene.

**Controls:** No movement controls. Edit the prefab or scene while running.

**Try editing:** [prefabs/skeleton.prefab.json](prefabs/skeleton.prefab.json): shared components and attachments. [scenes/main.scene.json](scenes/main.scene.json): instances and overrides.

Run from the repository root on Windows:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = '.exe'
odin run examples/prefabs_2d -linker:msvc -collection:rune=rune "-out:build/prefabs_2d$exe"
```

[All examples](../README.md)
