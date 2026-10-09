# Scene Transition 2D

Fade to black, replace the active scene, then fade back in.

**Controls:** Left-click starts a transition.

**Try editing:** [main.odin](main.odin): transition states and Fade_Duration. [scenes/blue.scene.json](scenes/blue.scene.json) and [scenes/pink.scene.json](scenes/pink.scene.json): the two scenes.

Run from the repository root on Windows:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = '.exe'
odin run examples/scene_transition_2d -o:none -linker:msvc -collection:rune=rune "-out:build/scene_transition_2d$exe"
```

[All examples](../README.md)
