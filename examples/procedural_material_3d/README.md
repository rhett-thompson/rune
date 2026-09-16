# Procedural Materials 3D

A sphere, cube, and flat swatch share a built-in noise material. Switch between
nine presets, then tweak the surface while it renders.

From the repository root:

```powershell
odin run examples/procedural_material_3d -collection:rune=rune -collection:r3d=third_party/r3d-odin
```

The example also appears under **3D** in the launcher.

| Control | Action |
| --- | --- |
| 1 / 2 / 3 | Stone / moss / hammered metal |
| 4 / 5 / 6 | Grass / granite / wood |
| 7 / 8 / 9 | Sand / terracotta / snow |
| N | Next noise seed |
| Up / Down | Finer / coarser noise scale |
| D | Cycle detail layers |
| Left / Right | Decrease / increase contrast |
| B | Toggle bump normals |
| Q / E | Decrease / increase map resolution: 8, 16, 32, 64, 128, 256, 512, 1024 pixels |
| F | Toggle retro sampling: nearest neighbor, no mipmaps or FXAA |
| R | Restore settings from the selected material file |
| Left drag | Orbit the camera |

Keyboard changes are temporary. Each preset has a matching file in `assets/`,
such as `grass.material.json`, `granite.material.json`, or `wood.material.json`.
Edit and save the selected file to keep changes and hot reload the surface.
The files also expose colors, roughness, metallic response, noise persistence,
and map resolution. Wood uses `"pattern": "wood"` for warped grain bands;
the other presets use layered noise with distinct colors and surface settings.

To save the retro look, set `"filter": "point"` and `"mipmaps": false` at the
top level of the material JSON. Set `procedural.resolution` to 8, 16, 32, or 64 for
larger, more visible pixels, and set `PostProcessing.anti_aliasing` to `"disabled"`
in the scene to keep the pixel edges sharp. **Q / E** changes resolution in
either sampling mode. **F** changes sampling and smoothing, preserving your
chosen resolution even when you edit it while retro sampling is active.
Toggling **F** off restores the previous filter settings. **R** restores noise,
resolution, and sampling settings from the selected file.

See [procedural material documentation](../../docs/procedural-materials.md)
for every field, map precedence, and UV mapping behavior.
