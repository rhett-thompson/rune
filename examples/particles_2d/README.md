# Particles 2D

Compare continuous emitters with a burst triggered from Odin.

**Controls:** Space emits a burst; E toggles the fountain and smoke; C clears live particles; F3 toggles gizmos.

**Try editing:** [scenes/main.scene.json](scenes/main.scene.json): rates, lifetime, velocity, colors, and blending. [assets/soft.png](assets/soft.png): smoke texture. [main.odin](main.odin): burst and toggle controls.

Run from the repository root with PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/particles_2d -collection:rune=rune "-out:build/particles_2d$exe"
```

[All examples](../README.md)
