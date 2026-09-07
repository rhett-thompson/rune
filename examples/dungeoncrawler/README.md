# Dungeon Crawler

Read a larger game with generated rooms, combat, enemy behavior, and textured dungeon rendering.

**Controls:** WASD moves; mouse or Left/Right looks; left-click or Space attacks; Left Shift sprints. R restarts after death.

**Try editing:** [game.odin](game.odin): generation, combat, and drawing. [main.odin](main.odin): component registration. [scenes/main.scene.json](scenes/main.scene.json): game settings. This example reads raylib input directly.

Run from the repository root with PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/dungeoncrawler -collection:rune=rune "-out:build/dungeoncrawler$exe"
```

[All examples](../README.md)
