# Skybox 3D

An atmospheric sky driven by a scene DirectionalLight, with an orbit camera and
a small lookout platform. The sun rotates automatically through a 60-second
day/night cycle, with a dim full moon rotating opposite it and a blue night fill.
Left-drag to orbit and TAB to compare atmospheric and gradient
procedural modes. The atmospheric sky follows the rotating light; the gradient
mode retains its independently configured sun. Edit the `Skybox` or
`DirectionalLight` in `scenes/main.scene.json` and save to see changes.
Set `atmosphere.moon` to `""` to omit the moon from the sky, and adjust
`atmosphere.night_energy` to brighten or darken the night background (zero disables
the fill). Disable the moon light entity to also remove its scene lighting.

From the repository root:

```powershell
odin build examples/skybox_3d -collection:rune=rune -collection:r3d=third_party/r3d-odin -out:build/skybox_3d.exe
./build/skybox_3d.exe
```

On Linux use `-out:build/skybox_3d` and `./build/skybox_3d`.
See [skybox authoring](../../docs/skybox.md) for image skies and runtime edits.
