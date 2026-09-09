# First Person 3D

A reusable `CharacterController3D` motor with first-person look and a movement
course. Blue ramps test slope following, orange stairs test step-up, purple
geometry requires crouching, and a green platform moves back and forth. A crate
can be pushed, and the red ramp is too steep to walk up.
A warm directional sun casts soft shadows, with cool ambient fill keeping
shaded surfaces readable. Tune the `sun` and `ambient` entities in the scene.

See the [controller guide](../../docs/character-controller-3d.md) for the API and limits.

**Controls:** WASD moves; mouse looks; Space jumps; Left Shift sprints; Left Ctrl crouches; Escape toggles the cursor; F3 shows gizmos.

**Try editing:** [controller.odin](controller.odin): input and camera look. Movement tuning lives in the scene's `CharacterController3D` component. [scenes/main.scene.json](scenes/main.scene.json): player settings and obstacles. [input/default.input.json](input/default.input.json): controls.

Crouching eases the camera down and back up over `0.18` seconds. Tune
`FirstPersonController.crouch_transition_time` in the scene; zero or a negative
value restores an instant transition. Releasing crouch under a low ceiling keeps
the view lowered until the motor can stand. Changing direction mid-transition
starts from the current camera height, and head bob is added on top. The collider
still changes immediately after its clearance checks; only eye height is animated.

Concrete footsteps use the player's named `AudioPlayer.footsteps` instance,
randomly choosing among four clips copied from the shared Small Sound Kit.
`FirstPersonController.footstep_stride` defaults to `2.4` world units between
steps (minimum `0.1`; zero disables footsteps). The first step plays as soon as
grounded movement begins; subsequent steps use the stride distance. Sprinting naturally plays steps
more often, while crouching plays them less often. Actual ground travel drives
the cadence: stopping, jumping, pushing a wall, and passive platform travel do
not trigger steps. Head bob can be disabled independently. Tune the audio
instance's `volume`, `random_pitch`, or `clips` list in the scene.

The player's `FirstPersonController` settings also control head bob:

| Field | Default | Meaning |
| --- | --- | --- |
| `head_bob_enabled` | `true` | Set to `false` to remove bob immediately. |
| `head_bob_vertical` | `0.018` | Vertical amplitude in world units (1.8 cm). |
| `head_bob_horizontal` | `0.009` | Side-to-side amplitude in world units (0.9 cm). |
| `head_bob_frequency` | `1.8` | Vertical cycles per second at walking speed; zero stops bob. |
| `head_bob_smoothing` | `12` | Blend response per second; lower values soften the motion and fade more slowly. |

Bob fades in during ground movement and returns to neutral when stopping or
jumping. Sprinting increases cadence; slower movement and crouching reduce both
cadence and strength. Blocked movement and passive platform travel do not drive
bob. These offsets affect only the camera, with no added roll or pitch. Negative
amplitudes are treated as zero; smoothing has a minimum of `0.1`.
Edit these values in the scene for hot reload, or try a temporary runtime change:
`set player FirstPersonController.head_bob_enabled false` in the developer console.

The placeholder carbine is drawn by [weapon.odin](weapon.odin) using a separate
camera and a transparent render texture with its own depth buffer. The result is
composited after the level and debug gizmos, before the HUD. This gives the weapon
the same basic separation as a camera overlay: walls never obscure it, while its
own parts still occlude one another. Its field of view is independent of the world
camera. This is an example-owned viewmodel pass, not a general camera stack.

Tune the player's `WeaponViewmodel` component in the scene:

| Field | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | Show or hide the placeholder. |
| `position` | `[0.24, -0.22, -0.5]` | Camera-local offset: right, up, backward; negative Z is forward. |
| `rotation` | `[-3, -6, -3]` | Local X/Y/Z rotation in degrees. |
| `scale` | `1` | Uniform size; zero or negative hides the weapon. |
| `fov` | `55` | Vertical overlay field of view in degrees, clamped to 10–120. |
| `jump_motion_strength` | `1` | Takeoff dip, airborne lag, and landing bounce strength; zero disables it, maximum 3. |

The target follows framebuffer size, is reused between frames, and is released
on shutdown. The weapon stays attached to the view during look and crouch, with
subtle sway from head bob. Jumping adds a downward dip and slight muzzle pitch,
followed by airborne lag and a damped landing bounce. Landing intensity follows
fall speed and is capped for large drops. Motion follows actual physics, including
walking off ledges, freezes while paused, and resets on scene reload. It changes
only the viewmodel; the camera and player movement are unaffected.
The placeholder uses face colors for shading; it does
not receive world shadows or post-processing, cast shadows into the level, or
provide firing/hit detection. Replace `draw_placeholder_weapon` with a model draw
to reuse this overlay for an authored weapon. Collision and future aiming logic
should still use the world camera and level physics.

Run from the repository root with PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/first_person_3d -collection:rune=rune -collection:r3d=third_party/r3d-odin "-out:build/first_person_3d$exe"
```

[All examples](../README.md)
