# Skeletal Animation 3D

Play skeletal clips independently on instances of a small generated arm model.

**Controls:** For the left model, P pauses; R resumes; 1 selects bend; 2 selects sway. The other models keep playing independently.

S cycles 0.5x/1x/2x speed, V reverses direction, and H silently seeks to one
second. The left rig emits impact sparks and sounds in `bend`, and a ground
ring plus footstep sounds in `sway`. The counters update only when markers fire,
including during the destination clip's blend. These are timing cues on the
existing two-joint test rig, with gameplay behavior defined in Odin.

Edit [assets/arm.model-events.json](assets/arm.model-events.json) to change marker
names/times while running. The `clip_events` console command returns effect
counters. See [the skeletal event API](../../docs/model-animation-events.md) for
reverse, seek, reload, and buffer rules. Sound cues reuse the bundled CC0
Brackeys platformer pack; see its `LICENSE & CREDITS.txt` under `examples/assets`.

**Try editing:** [scenes/main.scene.json](scenes/main.scene.json): animator settings. [main.odin](main.odin): playback controls. [generate_fixture.ps1](generate_fixture.ps1): source of the included arm model.

Run from the repository root with PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/skeletal_animation_3d -collection:rune=rune -collection:r3d=third_party/r3d-odin "-out:build/skeletal_animation_3d$exe"
```

[All examples](../README.md)
