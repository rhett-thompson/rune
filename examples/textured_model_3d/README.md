# Textured Model 3D

Load OBJ models with scene-authored materials and an orbit camera. Start with a
textured crate and inspect its individual material maps, or switch to a simple
rotating pyramid with a solid-color material.

**Controls:** Left-drag orbits; the mouse wheel zooms; Space switches between the
crate and pyramid scenes; Tab changes the crate's material view. The selected
material view is retained when returning to the crate.

**Try editing:** [assets/materials/crate.material.json](assets/materials/crate.material.json): textures and settings. [scenes/main.scene.json](scenes/main.scene.json): lights and model. [main.odin](main.odin): material view switching.

For the minimal model setup, edit [scenes/simple.scene.json](scenes/simple.scene.json),
[assets/models/pyramid.obj](assets/models/pyramid.obj), and
[assets/materials/pyramid.material.json](assets/materials/pyramid.material.json).
Set `startup_scene` in [project.json](project.json) to `scenes/simple.scene.json`
to start there directly. Both scenes support JSON hot reload.

Run from the repository root with PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/textured_model_3d -collection:rune=rune -collection:r3d=third_party/r3d-odin "-out:build/textured_model_3d$exe"
```

[All examples](../README.md)
