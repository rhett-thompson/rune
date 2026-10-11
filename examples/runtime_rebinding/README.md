# Runtime Rebinding

Replace keyboard bindings at runtime without changing the movement system.

**Controls:** Left/Right moves initially. R switches between arrows and A/D and saves the bindings. Later launches use the saved keys.

**Try editing:** [main.odin](main.odin): rebind_keyboard and input.save calls. [input/default.input.json](input/default.input.json): the file this example rewrites when R is pressed.

Run from the repository root on Windows:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = '.exe'
odin run examples/runtime_rebinding -o:none -linker:msvc -collection:rune=rune "-out:build/runtime_rebinding$exe"
```

[All examples](../README.md)

Controller: D-pad left/right moves; X switches and saves keyboard bindings. Controller bindings remain available after each save. Hold Start for one second to exit. Button names use Xbox layout.
