# Third Person 3D

A third-person version of the [first-person movement course](../first_person_3d/README.md),
using the same fixed-step `CharacterController3D` capsule motor, warm lighting,
shadows, and ambient occlusion. Walk up blue ramps, climb orange stairs, crouch
through the purple tunnel, ride the green moving platform, and push the crate.
The red ramp is deliberately too steep to climb.

Near the starting point, face the blue door and press **E** to open or close it.
The door slides over 0.8 seconds with a gentle start and stop, and its collision
follows the panel. Press E again to reverse it during travel. It refuses to close
on a character or blocking object, and reopens if the doorway becomes blocked
while closing. Tune the travel time in [door.odin](door.odin).
Face the golden cube and press **E** to collect it. Face the
purple guide and **hold E** to talk; the prompt shows hold progress. Release E
or turn away to cancel. Walls and terrain collision block interactions.
The bottom HUD shows the selected action and its result.

These use reusable `Interactor3D` / `Interactable3D` components; see the
[interaction guide](../../docs/interactions-3d.md). Effects live in
[interactions.odin](interactions.odin). Pickup and door changes last for the
current scene; a full reload restores the authored course.

**Controls:** WASD moves relative to camera yaw; Space jumps (release early for a
short hop); Left Shift sprints; Left Ctrl crouches; mouse wheel zooms. Left-drag
orbits the camera; right-drag also turns the character toward the camera's forward
direction. While moving normally, the character faces its movement direction.
F3 toggles physics gizmos. The HUD reports grounding, crouching, blocked standing,
and camera obstruction.

The camera and visible character interpolate the motor's fixed-step positions.
The character shrinks to match the effective crouch height and stays crouched
until the motor finds enough headroom. Turning and visual scaling affect child
entities; the player's feet Transform retains unit scale for native collision.
Camera target height eases during crouching. Obstacle rays pull the camera inward
immediately, then ease it outward when clear. The five-ray probe leaves a small
margin around the lens; it is not a full swept camera collider. When the camera
gets closer than 1.5 world units, the avatar hides so it cannot block the view,
then reappears as the camera moves back out.

Concrete footsteps use the first-person example's existing audio clips. They
follow actual ground travel, so pushing into walls or riding a platform while
stationary does not trigger walking sounds. Keep the neighboring example in place.

**Try editing:**

- [controller.odin](controller.odin): camera-relative input, orbit, obstruction checks, and visual facing.
- [main.odin](main.odin): lifecycle, moving platform, rendering, and HUD.
- [footsteps.odin](footsteps.odin): distance-based playback after physics.
- [scenes/main.scene.json](scenes/main.scene.json): course, lighting, player settings, and avatar parts.
- [input/default.input.json](input/default.input.json): controls.

Tune movement through `CharacterController3D`; see [the motor guide](../../docs/character-controller-3d.md).
The game-owned `ThirdPersonController` component controls the following:

| Setting | Default | Purpose |
| --- | --- | --- |
| `mouse_sensitivity`, `zoom_speed` | `0.25`, `0.8` | Orbit degrees per mouse unit and zoom units per wheel step. |
| `initial_yaw`, `initial_pitch` | `180`, `22` | Starting orbit angles in degrees, restored on full scene reload. |
| `distance`, `min_distance`, `max_distance` | `6`, `2`, `12` | Desired follow distance and zoom limits; obstruction may pull closer. |
| `target_height_ratio` | `0.65` | Camera target as a fraction of the effective capsule height. |
| `camera_smoothing` | `12` | Target-height and outward-distance responsiveness per second. |
| `collision_margin` | `0.2` | Camera probe spacing and clearance, clamped to 0.05–0.5 world units. |
| `turn_speed` | `12` | Visible character turn responsiveness per second. |
| `footstep_stride` | `2.4` | Ground travel per footstep; zero disables footsteps. |

Scene edits hot reload. A runtime or value-only edit to `distance` updates the
follow distance without resetting orbit yaw. Full reload resets the camera and
reacquires player, avatar, camera, and platform handles. The course is authored
locally so it can be edited independently of the first-person scene.

Run from the repository root with PowerShell 7, after installing the r3d dependency:

```powershell
git submodule update --init --recursive
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/third_person_3d -collection:rune=rune -collection:r3d=third_party/r3d-odin "-out:build/third_person_3d$exe"
```

[All examples](../README.md)
