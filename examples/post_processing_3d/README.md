# Post Processing 3D

A small light gallery demonstrating JSON-authored bloom, tone mapping, SSAO,
color adjustment, and optional depth of field. No external assets are required.

Build from the repository root:

```powershell
odin build examples/post_processing_3d -collection:rune=rune -collection:r3d=third_party/r3d-odin -out:build/post_processing_3d.exe
./build/post_processing_3d.exe
```

Linux uses `-out:build/post_processing_3d` and `./build/post_processing_3d`.

- **Space:** compare effects on/off.
- **B / O / D:** toggle bloom / ambient occlusion / depth of field.
- **T:** cycle tone mapping.
- **Up / Down:** change exposure.
- **Left-drag:** orbit.

Edit `scenes/main.scene.json` and save to hot reload. Keyboard adjustments are
runtime-only. The HUD is drawn after r3d and remains outside post-processing.
See [the engine documentation](../../docs/post-processing.md) for all settings,
camera overrides, code-first use, and console commands.
