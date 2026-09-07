# Textured Model 3D

Render a textured crate and switch material views to inspect individual maps.

**Controls:** Left-drag orbits; the mouse wheel zooms; Tab changes the material view.

**Try editing:** [assets/materials/crate.material.json](assets/materials/crate.material.json): textures and settings. [scenes/main.scene.json](scenes/main.scene.json): lights and model. [main.odin](main.odin): material view switching.

Run from the repository root with PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/textured_model_3d -collection:rune=rune -collection:r3d=third_party/r3d-odin "-out:build/textured_model_3d$exe"
```

[All examples](../README.md)
