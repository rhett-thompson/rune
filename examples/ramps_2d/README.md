# Ramps, chained dashes, wall jumps, and one-way platforms

A `CharacterController2D` accelerates a capsule up a convex polygon and onto a
two-sided segment bridge. It stays grounded while descending and supports
coyote time, jump buffering, and a configurable slope limit. A teal elevator
and violet shuttle demonstrate carrying and jump momentum. Stand still to ride
the elevator; jump right near its top to board the shuttle.
The gold diamond is a polygon sensor; an orange ray shows the ground below the
player. Green gizmos outline the actual collision geometry. No external assets
are required. Movement and drawing are Odin systems; all collision data is JSON.

From the repository root:

```powershell
odin build examples/ramps_2d -collection:rune=rune -out:build/ramps_2d.exe
./build/ramps_2d.exe
```

On Linux, use `-out:build/ramps_2d` and `./build/ramps_2d`.

Use A/D to move, Space to jump, and hold S or Down to crouch.
While holding S/Down, press Space to drop
through the violet shuttle or orange ledge. Both are one-way: jump through
them from below and land on top. The teal elevator remains solid.
Backtick opens the console.
The HUD shows the current support entity and its carry velocity.
Try `set shuttle PlatformMotion.speed 120` to change the shuttle speed.
Try `set player CharacterController2D.max_slope_angle 15` to make the ramp too
steep to climb, `set ramp PolygonCollider2D.vertices.1.1 -160`, or
`set bridge SegmentCollider2D.end [260,-80]`. Runtime edits are temporary;
edit `scenes/main.scene.json` to persist changes and see them hot reload.

For repeatable automation, launch with `--console-dir=build/console/ramps`, then
use `tools/console.ps1` with `pause`, `input move_right press`, `step 200`,
`input move_right release`, `step 1`, and `capture`.

The floor and walls are separate zero-thickness segments. The ramp has four
convex vertices, and the sensor has four vertices plus a local offset. The
example deliberately uses an identity camera for its simple terrain drawing.
Gameplay sends movement and jump requests to the built-in motor from a fixed
update callback. JSON sets speed, acceleration, gravity, jump speed, fall-speed
limit, slope limit, snap distance, coyote time, jump buffer time, drop speed,
and minimum drop guard time.
See the [controller API](../../docs/character-controller-2d.md) for setup and runtime state.
See [physics authoring](../../docs/physics.md) for winding, ownership, scale,
and segment limitations.

The platforms use kinematic `RigidBody2D` components. The example's custom
`PlatformMotion` component holds a 0/1 axis, minimum/maximum coordinates, and
speed; `platforms.odin` supplies velocity in the fixed update. Endpoint steps
are shortened to reach the bound without teleporting. The elevator and shuttle
complete their routes in six seconds with the authored speeds. Changing a
platform Transform is a teleport and detaches riders. Platform motion pauses
and steps with the rest of the simulation.

Walk off the right end of the bridge, land on the floor, and crouch left through
the low tunnel. Releasing S/Down inside leaves the character crouched until there
is room to stand. The HUD reports when a ceiling blocks standing. The tunnel has
46 units of clearance, versus a 64-unit standing and 40-unit crouched capsule.
The character drawing and physics gizmos follow the live capsule; the scene's
`CapsuleCollider2D` remains the standing authoring data. Tune `crouch_height` and
`crouch_speed` in `CharacterController2D` JSON or through the runtime console.

The top of the ramp has three 12-unit stairs. The player has `step_height: 18`,
so walking climbs the first stair without jumping. The low red bar blocks further
standing steps: hold S/Down to crouch and continue up the stairs. The capsule's
shorter shape fits while its standing shape does not. Try
`set player CharacterController2D.step_height 0` to disable the assistance.
The orange one-way ledge now sits above the right end of the bridge.

Tap Space for a short hop; hold it for the full jump. The example sends a jump
release edge to the controller and uses `jump_cut_multiplier: 0.5`. Set that
value to `1` to compare fixed-height jumps, or lower it for shorter taps. To reach
the orange ledge above the right bridge, hold Space through the ascent.
For console-driven comparisons, use `input jump press`, `step 1`,
`input jump release`, then `step 30` for a tap. Hold for about `step 25` before
releasing for a full jump. Buffering and coyote jumps also remember short taps.

## Wall shaft

Walk right past the tunnel into the shaft's lower opening. Jump toward its left
wall, then alternate A/D and Space presses to climb. Press toward a wall while
falling to slide. Hold Space for height; release early for a short hop.

This scene opts into `wall_slide_speed: 80`, `wall_jump_speed_x: 260`,
`wall_jump_speed_y: 360`, and `wall_jump_lock_time: 0.18`. The engine defaults
leave slide/jump speeds at zero. Try `set player CharacterController2D.wall_slide_speed 0`
to turn sliding off, or `set player CharacterController2D.wall_jump_speed_x 0`
to turn wall jumping off independently. See the controller's
[feature controls](../../docs/character-controller-2d.md#feature-controls).

## Chained dashes

Press Left Shift to dash in your current/last movement direction. Press again
during the dash to queue the next, or within 0.2 seconds afterward to continue.
Each dash lasts 0.14 seconds at speed 300. The scene allows three per chain and
then a 0.5-second cooldown. Steer before the next press to reverse direction.
Holding Shift does not repeat. Try the open floor to the right of the tunnel;
air dashes also work. The character turns cyan while dashing, and the HUD shows
chain index, queued input, and cooldown.

Use `set player CharacterController2D.dash_chain_count 5` to allow five dashes,
`dash_chain_count 1` for single dashes, or `dash_speed 0` to disable them (use the
same `set player CharacterController2D.` prefix). Ground/air permissions, gravity,
window, and cooldown are all JSON settings documented in the
[controller API](../../docs/character-controller-2d.md#dashes-and-chaining).
