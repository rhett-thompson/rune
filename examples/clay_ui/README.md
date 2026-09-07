# Clay UI

Build a Clay menu that pauses simulation and captures gameplay input while remaining interactive.

**Controls:** Mouse or Up/Down/Tab navigates; Enter selects; Left/Right adjusts volume. Escape toggles the menu. Gamepad D-pad, A, and B also work. A/D moves when resumed; F11 toggles fullscreen.

**Try editing:** [main.odin](main.odin): layout, focus, input capture, and audio volume. [input/default.input.json](input/default.input.json): UI actions.

Run from the repository root with PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/clay_ui -collection:rune=rune "-out:build/clay_ui$exe"
```

[All examples](../README.md)
