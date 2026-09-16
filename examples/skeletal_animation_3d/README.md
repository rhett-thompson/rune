# Skeletal Animation 3D

Play skeletal clips independently on three instances of a small generated arm
model, alongside the Strut Walking character on the right.

The scene uses the shared [3D environment prefab](../shared/prefabs/environment_3d.prefab.json)
for its blue skybox, ground with collision, warm sun with soft shadows, cool
ambient fill, and SSAO, matching the first-person and third-person examples.
Tune the prefab defaults or add `child_overrides` to the scene's `environment`
instance for local changes; see [shared environments](../../docs/prefabs.md#shared-3d-environment).

The character loads [../assets/Strut Walking.fbx](../assets/Strut%20Walking.fbx)
directly and loops its embedded `mixamo.com` clip. Its scene scale is `0.01`
to convert the source centimeters to meters. Rune's importer keeps FBX pivot
animation on the skeleton joints; no conversion step is needed. See the
[native importer fix](../../third_party/r3d-importer/README.md).

**Controls:** For the left model, P pauses; R resumes; 1 selects bend; 2 selects sway. The other models keep playing independently.

Left-drag to orbit, middle-drag to pan, and scroll the mouse wheel to zoom.
Panning moves the camera and its orbit target together in the view plane;
dragging follows the pointer, with speed scaled to the current zoom distance.
Press **Space** to play `Punching.fbx` on the walking character, then blend
back to walking. Pressing Space again restarts the punch. The animation-only
file reuses the character's skeleton and materials; it needs no skin.
The walking character has a blue surface (material slot 0) and gray joints
(slot 1), both lit with metallic highlights. Edit the
[surface material](assets/materials/strut.material.json) or
[joint material](assets/materials/strut-joints.material.json) to adjust their
colors, metallic response, and roughness while the example runs.

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
