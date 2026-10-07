# Custom Mover

Give an entity a Mover component, read an input axis, and update its Transform in Odin.

**Controls:** A/D or Left/Right moves the circle. Crossing the right edge wraps it to the left.

**Try editing:** [mover.odin](mover.odin): movement and wrapping. [scenes/main.scene.json](scenes/main.scene.json): Mover.speed. [input/default.input.json](input/default.input.json): movement keys.

Run from the repository root on Windows:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = '.exe'
odin run examples/custom_mover -linker:msvc -collection:rune=rune "-out:build/custom_mover$exe"
```

[All examples](../README.md)
