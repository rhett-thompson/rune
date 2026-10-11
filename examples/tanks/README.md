# Tanks

Combine custom components, wall ricochets, and an opponent that aims bank shots.

**Controls:** W/S drives and A/D turns the left tank; mouse aims and left-click fires. In two-player mode, arrows drive/turn the right tank and Enter fires. P changes mode; R restarts.

**Try editing:** [tanks_game.odin](tanks_game.odin): movement, shots, and opponent logic. [scenes/main.scene.json](scenes/main.scene.json): arena and match settings.

Run from the repository root on Windows:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = '.exe'
odin run examples/tanks -o:none -linker:msvc -collection:rune=rune "-out:build/tanks$exe"
```

[All examples](../README.md)

Controller: Pad 0 controls the blue tank and pad 1 the orange tank: left stick drives/turns, right stick aims and RT fires. A released aiming stick holds the last turret heading. Moving the mouse retakes blue-tank aiming; orange keeps keyboard hull aiming until pad 1 first aims. Tap Start toggles players and Back restarts. Hold Start for one second to exit. Button names use Xbox layout.
