# Hello World

Register a small Greeting component and draw its text at the entity's Transform position.

**Controls:** No movement controls.

**Try editing:** [scenes/main.scene.json](scenes/main.scene.json): change Greeting.text or Transform.position and save while running. [main.odin](main.odin): registration and drawing.

Run from the repository root with PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/hello_world -collection:rune=rune "-out:build/hello_world$exe"
```

[All examples](../README.md)
