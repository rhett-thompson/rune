# Skeletal Animation 3D

Play skeletal clips independently on instances of a small generated arm model.

**Controls:** For the left model, P pauses; R resumes; 1 selects bend; 2 selects sway. The other models keep playing independently.

**Try editing:** [scenes/main.scene.json](scenes/main.scene.json): animator settings. [main.odin](main.odin): playback controls. [generate_fixture.ps1](generate_fixture.ps1): source of the included arm model.

Run from the repository root with PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/skeletal_animation_3d -collection:rune=rune -collection:r3d=third_party/r3d-odin "-out:build/skeletal_animation_3d$exe"
```

[All examples](../README.md)
