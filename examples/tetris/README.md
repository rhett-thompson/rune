# Tetris

Implement board collision, rotation, line clearing, scoring, and a ghost piece with plain Odin state.

**Controls:** Left/Right or A/D moves; Down/S soft-drops; Space hard-drops; Up/X rotates clockwise; Z rotates counterclockwise; P pauses; R restarts.

**Try editing:** [main.odin](main.odin): board rules, timing, and drawing. [scenes/main.scene.json](scenes/main.scene.json): audio entities. The board is maintained in Odin, not as individual scene entities.

Run from the repository root with PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/tetris -collection:rune=rune "-out:build/tetris$exe"
```

[All examples](../README.md)
