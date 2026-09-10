# Highland Walk

A 256×256-unit landscape authored as a 16-bit PNG heightmap and terrain JSON.
Rune renders sixteen chunks and provides matching static triangle collision.
Grass, dirt and rock from the shared `HandPaintedTextures_512` folder blend
across the landscape based on local height and slope. Three-axis texture
projection keeps steep faces from stretching.

From the repository root:

```powershell
odin build examples/terrain_3d -collection:rune=rune -collection:r3d=third_party/r3d-odin -out:build/terrain_3d.exe
./build/terrain_3d.exe
```

On Linux, omit `.exe`. The example is also available in the launcher.

WASD moves, Shift sprints, Space jumps, Escape captures/releases the mouse,
and R resets the player. Mouse look starts active. After releasing the cursor,
click inside the window or press Escape to recapture it. The HUD shows the
current mouse mode. Close the window to exit. Walking off the map resets
the player after falling below it.

Edit `assets/hills.png` in a grayscale image editor, or change
`assets/hills.terrain.json` while the example runs. The heightmap and descriptor
reload together with collision. A corrupt edit keeps the last working terrain.
Use the runtime console's `pause`, `step`, `inspect`, `profile`, and `capture`
commands for repeatable inspection; see [the terrain guide](../../docs/terrain.md).

Tune `blend.dirt_height`, `blend.rock_slope`, `blend.noise_strength`, and
`uv_scale` in `assets/hills.terrain.json` while running. The current UV scale
repeats each texture every four terrain units. The base material is white so it
preserves the texture colors.

The heightmap is an original procedural sample shipped under Rune's license.
The hand-painted textures are supplied separately in the shared example assets;
their licensing is separate from Rune's heightmap and code. Sculpting, manually
painted layer masks, streaming, and LOD are outside this example.
