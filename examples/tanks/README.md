# Tanks

Combine custom components, wall ricochets, and an opponent that aims bank shots.

**Controls:** W/S drives and A/D turns the left tank; mouse aims and left-click fires. In two-player mode, arrows drive/turn the right tank and Enter fires. P changes mode; R restarts.

**Try editing:** [tanks_game.odin](tanks_game.odin): movement, shots, and opponent logic. [scenes/main.scene.json](scenes/main.scene.json): arena and match settings.

Run from the repository root with PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/tanks -collection:rune=rune "-out:build/tanks$exe"
```

[All examples](../README.md)
