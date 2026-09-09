# Highland Walk

A 256×256-unit landscape authored as a 16-bit PNG heightmap and terrain JSON.
Rune renders sixteen chunks and provides matching static triangle collision.

From the repository root:

```powershell
odin build examples/terrain_3d -collection:rune=rune -collection:r3d=third_party/r3d-odin -out:build/terrain_3d.exe
./build/terrain_3d.exe
```

On Linux, omit `.exe`. The example is also available in the launcher.

WASD moves, Shift sprints, Space jumps, Escape captures/releases the mouse,
and R resets the player. The mouse starts released. Walking off the map resets
the player after falling below it.

Edit `assets/hills.png` in a grayscale image editor, or change
`assets/hills.terrain.json` while the example runs. The heightmap and descriptor
reload together with collision. A corrupt edit keeps the last working terrain.
Use the runtime console's `pause`, `step`, `inspect`, `profile`, and `capture`
commands for repeatable inspection; see [the terrain guide](../../docs/terrain.md).

The heightmap is an original procedural sample shipped under Rune's license.
It contains no external artwork. Sculpting, painted layers, streaming, and LOD
are outside this first example.
