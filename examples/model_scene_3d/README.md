# Model Scene 3D

Render an OBJ model with a scene material and an orbit camera.

**Controls:** Left-drag orbits; the mouse wheel zooms.

**Try editing:** [assets/models/pyramid.obj](assets/models/pyramid.obj): geometry. [assets/materials/pyramid.material.json](assets/materials/pyramid.material.json): appearance. [scenes/main.scene.json](scenes/main.scene.json): placement and camera.

Run from the repository root with PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/model_scene_3d -collection:rune=rune -collection:r3d=third_party/r3d-odin "-out:build/model_scene_3d$exe"
```

[All examples](../README.md)
