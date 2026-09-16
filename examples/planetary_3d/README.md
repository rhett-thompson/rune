# Pocket Planets

A third-person planetary platforming example: four sculpted icosahedrons float
in space, each with its own radial gravity. Explore every world, including its
underside, and jump between them through the golden launch markers.

## Run

From the repository root (no additional collections or downloaded assets):

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/planetary_3d -collection:rune=rune "-out:build/planetary_3d$exe"
```

Or select **Pocket Planets** in the example launcher.

| Control | Action |
| --- | --- |
| WASD | Move relative to the camera in the local ground plane |
| Space | Jump; hold for a full interplanetary jump, release early for a short hop |
| Shift / Ctrl | Sprint / crouch |
| Left or right mouse drag | Orbit the third-person camera |
| Mouse wheel | Zoom |
| R | Return to Verdant and clear exploration progress |

Walk into a golden ring, stop moving, then hold Space. The dotted line points
toward the next world. Keep holding through takeoff; its gravity catches you
past the midpoint. WASD steers in flight. Every route, including Glacier back
to Verdant, is reachable with the normal jump. Landing on all four worlds
completes the expedition. R also recovers a missed jump; drifting more than
65 units from the nearest center automatically returns you home.

## Built-in systems

- The same `CharacterController3D` used by the first- and third-person examples:
  capsule sweeps, collision-plane sliding, slopes, stairs, crouch clearance,
  coyote time, buffered/variable jumps, and pushing. The new
  `ecs.character_controller_3d_move_on_plane` supplies world movement and local up.
- Rune's fixed-step scene loop, input actions, asset manager, and `AudioPlayer`.
  Footsteps reuse the four concrete clips from `first_person_3d`, with randomized
  pitch. Ground travel triggers them; walls and airborne motion do not.
- A built-in `Camera3D` entity exposes the gravity-following view to Rune's
  camera tools and gizmos; the example supplies its orbit behavior.
- Twelve `RigidBody3D` / `SphereCollider` props. World gravity is disabled for
  these bodies; native Box3D forces pull them toward the nearest planetoid.
- Box3D's triangle mesh shapes, shared with the drawn terrain vertices. A
  planetoid uses 162 welded vertices and 320 outward-facing triangles, with
  broad ridges and a depressed basin. Subdivision preserves the original
  icosahedron's large-scale facets. The example owns these procedural meshes
  and registers their native bodies/shapes with Rune's physics lookup tables.
- Built-in raylib primitives draw the astronaut, props, stars, and launch guides;
  shared example typography draws the HUD. There are no new image/audio assets.

Gravity selection, terrain generation, and camera behavior are example-owned.
Gravity has constant magnitude toward the nearest nominal surface, with a
0.8-unit switching margin to avoid flicker. It is an arcade field, not an
inverse-square orbital simulation. The camera transports its heading with local
up, eases gravity flips with limited angular speed and acceleration, interpolates fixed-step motion, and
probes obstacles before positioning its lens. Camera and avatar transforms do
not rotate or scale the motor's feet transform.
The camera's aim offset follows the eased horizon so crossing between gravity
wells does not instantly shift the look-at point.
The astronaut's visual up and facing also ease into their new orientation,
independently of camera orbit. The collision capsule still aligns immediately
with local gravity, keeping movement and landing behavior consistent.

## Tune

Both `player` and `follow_camera` have a custom **`OrientationSmoothing`** component
in `scenes/main.scene.json`. Tune them independently; existing behavior is the default:

```json
"OrientationSmoothing": {
  "max_turn_speed": 2.4,
  "angular_acceleration": 5,
  "easing_rate": 5,
  "facing_turn_speed": 8,
  "facing_easing_rate": 12
}
```

| Field | Meaning |
| --- | --- |
| `max_turn_speed` | Maximum gravity alignment speed, radians/second |
| `angular_acceleration` | How quickly the alignment speeds up/slows down, radians/second² |
| `easing_rate` | How quickly alignment settles near its target, 1/second |
| `facing_turn_speed` | Player's maximum turn toward movement, radians/second |
| `facing_easing_rate` | Player's movement-facing responsiveness, 1/second |

Lower values give slower, gentler turns. The two `facing_` fields apply only to
the player. Omitted fields (or a missing component) use the defaults; nonpositive
or nonfinite rates fall back to their defaults when read. Values are read every
frame, so console component edits apply immediately. Saving scene JSON triggers
the normal scene reload; this example rebuilds its generated planets on reload.

`scenes/main.scene.json` owns player movement and audio settings. `PLANETS` in
`planets.odin` sets centers, radii, terrain relief, seeds, and colors. Keep the
surface gaps reachable with the configured jump (`jump_speed² / (2 * gravity)`
is the approximate rise before a gravity handover). The launch route tests catch
unreachable gaps or non-walkable launch markers after terrain/layout changes.

## Validation

```powershell
odin test examples/planetary_3d -collection:rune=rune "-out:build/planetary_3d_test$exe"
odin run tools/character_controller_3d_validation -collection:rune=rune "-out:build/character_controller_3d_validation$exe"
```

The example test checks welded mesh topology, outward winding, all four jump
routes, sustained surface contact, and underside traversal with the real Box3D
backend. The engine validator includes sideways/upside-down movement, jump cut,
landing, and tilted capsule triggers alongside the existing movement regressions.

For a short render/audio smoke test that captures `build/planetary_3d.png` and
exits, run the built executable with `--smoke-test`.
