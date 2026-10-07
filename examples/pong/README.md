# Pong

Follow a small game split into component definitions, scene configuration, and gameplay code.

**Controls:** W/S controls the left paddle; Up/Down controls the right in two-player mode. Space serves; P changes player mode; R restarts.

**Try editing:** [pong_game.odin](pong_game.odin): game rules and drawing. [scenes/main.scene.json](scenes/main.scene.json): arena, paddle, ball, and match settings.

Run from the repository root on Windows:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = '.exe'
odin run examples/pong -linker:msvc -collection:rune=rune "-out:build/pong$exe"
```

[All examples](../README.md)
