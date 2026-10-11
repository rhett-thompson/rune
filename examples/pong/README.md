# Pong

Follow a small game split into component definitions, scene configuration, and gameplay code.

**Controls:** W/S controls the left paddle; Up/Down controls the right in two-player mode. Space serves; P changes player mode; R restarts.

**Try editing:** [pong_game.odin](pong_game.odin): game rules and drawing. [scenes/main.scene.json](scenes/main.scene.json): arena, paddle, ball, and match settings.

Run from the repository root on Windows:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = '.exe'
odin run examples/pong -o:none -linker:msvc -collection:rune=rune "-out:build/pong$exe"
```

[All examples](../README.md)

Controller: Pad 0 controls the left paddle and pad 1 the right paddle with left stick or D-pad up/down; A serves, tap Start toggles one/two players and Back restarts. Hold Start for one second to exit. Button names use Xbox layout.
