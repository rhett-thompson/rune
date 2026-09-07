# Runtime Rebinding

Replace keyboard bindings at runtime without changing the movement system.

**Controls:** Left/Right moves initially. R switches between arrows and A/D and saves the bindings. Later launches use the saved keys.

**Try editing:** [main.odin](main.odin): rebind_keyboard and input.save calls. [input/default.input.json](input/default.input.json): the file this example rewrites when R is pressed.

Run from the repository root with PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/runtime_rebinding -collection:rune=rune "-out:build/runtime_rebinding$exe"
```

[All examples](../README.md)
