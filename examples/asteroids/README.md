# Asteroids

Build an arcade loop with pooled bullets, asteroid spawning, particles, and audio.

**Controls:** A/D or Left/Right turns; W or Up thrusts; Space fires; R restarts.

**Try editing:** [game.odin](game.odin): gameplay and drawing. [asteroid_spawner.odin](asteroid_spawner.odin): spawning. [components.odin](components.odin) and [scenes/main.scene.json](scenes/main.scene.json): game data.

Run from the repository root with PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/asteroids -collection:rune=rune "-out:build/asteroids$exe"
```

[All examples](../README.md)
