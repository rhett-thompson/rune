# Ramps, crouching, moving platforms, and one-way ledges

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
