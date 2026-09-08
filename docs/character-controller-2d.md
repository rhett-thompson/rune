# CharacterController2D

`CharacterController2D` is a fixed-step platformer motor built on Box2D. Gameplay
supplies a horizontal movement axis and jump requests. The motor handles
acceleration, gravity, slope following, ground snapping, jumping, coyote time,
jump buffering, one-way platforms, drop-through, and moving-platform support. Settings are ordinary scene/prefab JSON; behavior stays in
Odin. The [ramps example](../examples/ramps_2d/README.md) demonstrates it.

## Setup

Put these components on the same entity:

```json
"Transform": {"position": [140, 420, 0]},
"RigidBody2D": {"type": "dynamic"},
"CapsuleCollider2D": {
  "radius": 18,
  "height": 64,
  "axis": "vertical",
  "offset": [0, -32]
},
"CharacterController2D": {
  "move_speed": 200,
  "acceleration": 1600,
  "air_acceleration": 800,
  "gravity": 1200,
  "jump_speed": 460,
  "max_fall_speed": 900,
  "max_slope_angle": 45,
  "ground_snap_distance": 8,
  "coyote_time": 0.1,
  "jump_buffer_time": 0.1,
  "drop_speed": 60,
  "drop_time": 0.15
}
```

All controller fields are optional and default to the values above. Distances
use world units, speeds use units/second, acceleration and gravity use
units/second squared, angles use degrees, and grace periods use seconds.
Positive Y points down, so a jump has negative Y velocity.

The motor requires a dynamic `RigidBody2D` and a solid vertical capsule. Extra
sensor colliders are supported; additional solid colliders are not supported by
its capsule ground sweep. Both X/Y scales must be nonzero. Capsule offsets,
reflections, and nonuniform scaling use the same geometry as the regular
[2D colliders](physics.md). Transform rotation and parent transforms do not
rotate or reposition native physics.

Code-first assembly can add the components in any order. The motor stays
inactive while its setup is incomplete or incompatible; the remaining physics
components keep their ordinary behavior. `character_controller_2d_ready` checks
the setup, and the runtime state's `active` flag reports whether the motor ran.
This also allows components to be removed or replaced during gameplay.

## Movement API

```odin
control :: proc(game: ^rune.Engine, world: ^ecs.World) {
    ecs.character_controller_2d_move(
        world, player, input.axis(rune.input_state(game), "move_x"),
    )
    if input.pressed(rune.input_state(game), "jump") {
        ecs.character_controller_2d_jump(world, player)
    }
}
```

Register that callback as a system's `fixed_update`. The engine runs the motor
inside each fixed physics step after game systems and before Box2D simulation.
`post_physics` callbacks see the resulting position, velocity, and grounded state.
Standalone users call `ecs.physics_2d_update`; no extra controller update call
is needed.

`character_controller_2d_move` clamps a finite axis to `[-1, 1]`. It persists
until replaced, so send zero to stop. Acceleration applies on the ground and
`air_acceleration` applies in the air; zero air acceleration disables air control.
`move_speed` is horizontal speed, with vertical velocity following the slope.

`character_controller_2d_jump` queues an edge for the next fixed simulation
step. Call it on a press, not every frame while a button is held. Requests can
also come from an ordinary update callback; frames without a physics step keep
the request pending. The controller does not read input mappings itself.

```odin
settings := ecs.default_character_controller_2d()
settings.move_speed = 240
ecs.add(world, registry, player, settings)

settings.max_slope_angle = 35
ecs.set(world, player, settings)

state, found := ecs.get_character_controller_2d_state(world, player)
if found && state.active && state.grounded {
    // state.ground_normal points away from the supporting surface (up is -Y).
}
body, _ := ecs.get_rigid_body_2d(world, player)
// body.velocity and body.grounded reflect the latest motor/physics result.
```

## Grounding and jumps

Walkable contacts have a normal within `max_slope_angle` of up. Horizontal input
into steeper surfaces is blocked. Grounded velocity follows a walkable slope's
tangent, allowing ascent, descent, and stopping without gravity-induced drift.
The motor uses a frictionless capsule and integrates its own gravity; the
configured `RigidBody2D.gravity_scale` remains stored but is ignored while the
motor is active. Ordinary body behavior is restored when the controller is
removed or its setup becomes incompatible.

A downward sweep of the complete capsule maintains support across short drops
up to `ground_snap_distance`. It ignores the character's own shapes and sensors,
respects collision layers, and stops at the nearest solid hit. Steep surfaces
cannot be snapped onto. A long snap only maintains existing ground contact;
falling characters must reach the ground, and jumps are not pulled back down.
Set snap distance to zero to disable this assistance.

`coyote_time` allows a jump briefly after walking off a ledge. `jump_buffer_time`
keeps a press made shortly before landing and consumes it on the next supported
fixed step. Each request can launch once; expired requests do not trigger later
jumps. Setting either period to zero disables that grace window while retaining
normal grounded jumping. `jump_speed = 0` disables jumping.

Box2D's world maximum linear speed still applies to the combined velocity. Its
current default is 400 world units/second, so high jump/fall settings may be
limited earlier by the backend. The motor does not raise this global ceiling
for other bodies. Games needing higher speeds can explicitly tune
`b2.World_SetMaximumLinearSpeed` on `world.box2d_world` after initialization.

This is a small rigid-body motor. It has no stair step-up,
wall jumps, crouching, or crush handling. Dynamic-body
contacts and sensor events continue through the normal physics APIs.

## Moving platforms

A supporting body's linear velocity carries the character through the same
Box2D step as normal movement. No position offset is applied afterward, so
carrying respects walls and ceilings. Horizontal input is relative to the
platform, and standing still matches its horizontal and vertical motion.
Descending platforms retain support even with ground snapping disabled.

Author a platform with `Transform`, a solid collider, and a kinematic
`RigidBody2D`:

```json
"Transform": {"position": [150, 480, 0]},
"BoxCollider2D": {"size": [100, 16], "offset": [0, 8]},
"RigidBody2D": {"type": "kinematic", "gravity_scale": 0}
```

Move it from an Odin `fixed_update` system, before the engine physics step:

```odin
body, found := ecs.get_rigid_body_2d(world, elevator)
if found {
    body.velocity = {0, -60}
    ecs.set_rigid_body_2d(world, elevator, body)
}
```

Use velocity for continuous travel. Setting `Transform.position` is a teleport:
it detaches riders rather than dragging them to the new position. The example's
custom `PlatformMotion` data stores axis, bounds, and speed in JSON, while
[platforms.odin](../examples/ramps_2d/platforms.odin) reverses kinematic velocity
at the endpoints. No built-in platform/path component is required.

Runtime state exposes `support_entity`, `support_component`, and `support_velocity`. While grounded,
these identify the supporting entity and its current velocity. After walking
off, the last support is retained only during coyote time so a delayed jump can
inherit departure velocity. A jump clears the support handle immediately.

A jump adds the platform's vertical velocity to the upward jump velocity and
preserves its horizontal velocity. Air control acts relative to that inherited
horizontal motion until landing; the platform cannot steer an already airborne
character. An upward elevator boosts world-space jump velocity and a downward
elevator reduces it. The character is allowed to separate upward relative to
a descending elevator even when both are moving downward in world coordinates.
The global Box2D speed ceiling still applies.

Removal, disabling, layer changes, shape rebuilds, body-type changes, and
teleporting a platform invalidate its riders' support and coyote eligibility.
Value reload does the same when it changes that native geometry, even if entity
IDs survive. Existing momentum remains part of the character's velocity; the
removed platform supplies no further carry. A rebuilt platform can be acquired
again without adding its velocity twice. Already launched momentum survives
removal of the source platform.

The engine's native 2D bodies have fixed rotation, so support uses linear
velocity, not rotating-platform attachment. Kinematic velocity-driven platforms
are the intended authoring path; ordinary dynamic support contacts still use
that body's current velocity. This is not a crush solver: design enough clearance
for the rider, since a kinematic platform will not stop itself when pinning a
character against another obstacle. Stable support selection prefers the
previous supporting body at equal-slope seams.

## One-way platforms and dropping

Set `"one_way": true` on a `BoxCollider2D` or a horizontal `SegmentCollider2D`:

```json
"BoxCollider2D": {"size": [120, 12], "offset": [0, 6], "one_way": true}
```

The horizontal top catches solid bodies descending from above, while sides and
undersides let them pass. This works for ordinary dynamic bodies as well as the
controller. Motion is relative to the platform, so kinematic platforms can move
horizontally or vertically. Use velocity for that motion, as described above.
`one_way` defaults to false. One-way sensors and sloped one-way segments are
rejected; ordinary sloped segments remain two-sided.

In Odin, request a drop from the current one-way support:

```odin
if input.pressed(rune.input_state(game), "jump") {
    if input.is_down(rune.input_state(game), "move_down") {
        ecs.character_controller_2d_drop_through(world, player)
    } else {
        ecs.character_controller_2d_jump(world, player)
    }
}
```

The API returns false while airborne, disabled, or standing on ordinary solid
ground. An accepted request waits for the next fixed step, overrides a concurrent
jump, and clears jump buffering and coyote time. `drop_speed` (default 60) supplies
a downward departure speed relative to the platform; gravity and the normal
fall-speed/backend limits still apply. Horizontal platform momentum is retained.

Only the supporting collider is ignored. A lower one-way platform or solid floor
can catch the character. The guard lasts at least `drop_time` seconds (default
0.15), then waits until the capsule is entirely clear of that collider.
Usually this means below or beside it; a subsequent jump can also clear above
it when a nearby floor prevented the capsule from fitting entirely underneath.
This prevents ground snapping or an expired timer from reattaching a character
inside a thick platform. `drop_entity` and `drop_component` identify the guarded
collider in runtime state. Removal, disabling, shape edits, teleports, reloads
that change geometry, and controller resets clear the affected guard.

Contact events report admitted top contacts, not underside passage. Sensor
behavior is unchanged. General raycasts and overlaps remain geometric, so a ray
can still hit a one-way platform from below; the motor's ground sweep separately
applies the one-way and drop rules.

## Editing and lifetime

Settings serialize through the registry, support prefabs and value reload, and
are editable with the runtime console:

```text
inspect player CharacterController2D
set player CharacterController2D.move_speed 250
set player CharacterController2D.max_slope_angle 15
set player CharacterController2D.ground_snap_distance 0
inspect player RigidBody2D
```

Only configuration is serialized. Input requests, ground normals, jump state,
and grace timers are runtime state. A changed configuration clears requests and
grace state, retains the current body velocity, and redetects ground support.
An unchanged configuration preserves runtime state during a value reload.
Teleports, shape rebuilds, physics shutdown, removal, and disabling the entity
or its parent clear input, support, and grace state. The velocity reference
already included in the body velocity is retained to avoid double carrying on
reacquisition. Re-enabling starts with zero movement input;
send movement again from your game system. Pausing simulation freezes timers
and does not consume requests.

Validation rejects unknown fields, non-finite or negative settings, zero
acceleration/gravity/fall/drop speed, slope angles of 89 degrees or greater, and grace/drop
periods longer than one second. Invalid typed setters and console edits preserve
the previous configuration.

The headless `tools/character_controller_2d_validation` executable covers data
validation, acceleration, stopping, slope limits, descent, snapping, ceilings,
jump grace, sensors, timing, activation, teleportation, removal, and prefab reload.
It runs as part of `tools/validate.ps1` on Windows and Linux.

`tools/moving_platform_2d_validation` additionally checks horizontal/vertical
carrying, reversal, descending support with snapping disabled, jump inheritance,
coyote departure, collision obstruction, and support invalidation/reload. It is
included automatically by `tools/validate.ps1`.

`tools/one_way_2d_validation` checks upward passage, landing, moving platforms,
selective drops, thick-platform guards, ordinary bodies, data validation and
invalidation. It is included automatically by `tools/validate.ps1`.
