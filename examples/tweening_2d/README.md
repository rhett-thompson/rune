# Tweening 2D

Use a repeating tween to animate an orb's position and color.

**Controls:** Left-click cycles through the easing curves.

**Try editing:** [main.odin](main.odin): easing_options, endpoints, colors, and duration. [scenes/main.scene.json](scenes/main.scene.json): the orb entity. Odin changes require a rebuild.

Run from the repository root with PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/tweening_2d -collection:rune=rune "-out:build/tweening_2d$exe"
```

[All examples](../README.md)
