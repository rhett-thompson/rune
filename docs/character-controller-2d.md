# CharacterController2D

`CharacterController2D` is a fixed-step platformer motor built on Box2D. Gameplay
supplies a horizontal movement axis and jump requests. The motor handles
acceleration, gravity, slope following, ground snapping, jumping, coyote time,
jump buffering, variable-height jumps, wall sliding/jumping, chained dashes, crouching, step-up, one-way platforms, drop-through, and moving-platform support. Settings are ordinary scene/prefab JSON; behavior stays in
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
  "jump_cut_multiplier": 0.5,
  "max_fall_speed": 900,
  "max_slope_angle": 45,
  "ground_snap_distance": 8,
  "coyote_time": 0.1,
  "jump_buffer_time": 0.1,
  "drop_speed": 60,
  "drop_time": 0.15,
  "crouch_height": 20,
  "crouch_speed": 100,
  "step_height": 0,
  "wall_slide_speed": 0,
  "wall_jump_speed_x": 0,
  "wall_jump_speed_y": 0,
  "wall_jump_lock_time": 0.15,
  "dash_speed": 0,
  "dash_duration": 0.15,
  "dash_cooldown": 0.4,
  "dash_chain_count": 1,
  "dash_chain_window": 0.15,
  "dash_on_ground": true,
  "dash_in_air": true,
  "dash_gravity_scale": 0
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
    if input.released(rune.input_state(game), "jump") {
        ecs.character_controller_2d_release_jump(world, player)
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
normal grounded jumping. `jump_speed = 0` disables ground and coyote jumps; wall jumps have separate speeds.

Box2D's world maximum linear speed still applies to the combined velocity. Its
current default is 400 world units/second, so high jump/fall settings may be
limited earlier by the backend. The motor does not raise this global ceiling
for other bodies. Games needing higher speeds can explicitly tune
`b2.World_SetMaximumLinearSpeed` on `world.box2d_world` after initialization.

This is a small rigid-body motor. It has no crush handling. Dynamic-body
contacts and sensor events continue through the normal physics APIs.

## Variable-height jumps

A press launches the normal jump. Release early for a short hop:

```odin
if input.released(rune.input_state(game), "jump") {
    ecs.character_controller_2d_release_jump(world, player)
}
```

`jump_cut_multiplier` controls how much remaining upward jump velocity is
retained on release. Its default is `0.5`; `0` removes the remaining jump portion,
and `1` disables cutting. Values must be finite and between 0 and 1. Holding jump
keeps the full trajectory. Existing code that sends only jump presses retains
its previous full jumps; no new held-input API is required.

Release is an edge latched until the next fixed simulation step. It applies at
most once per launched jump and does not accelerate a falling character or
shorten unrelated upward motion. A release received after the apex does nothing.
No transform, collider, horizontal velocity or gravity setting is changed.

The motor cuts velocity relative to the supporting body's vertical velocity at
takeoff. This preserves the platform contribution, including jumps from a
descending platform that are already moving down in world space. The takeoff
reference is frozen: reversing or removing the source cannot steer the jump.
The normal native speed ceiling and fall-speed limit still apply.

A press and release before the same fixed step produce a short jump. A buffered
press remembers its release through landing, so a quick tap made in the air
cannot become a full jump later. A newer press replaces that buffer's release
state. Expired buffers discard it. Coyote jumps use the same rules, and a drop
request takes priority over both edges. Send edges in input order when calling
the API directly; an older release does not shorten a newer held press.

Runtime state exposes `jump_release_requested`, `jump_buffer_released`,
`jump_cut_available`, `jump_cut_applied`, and `jump_launch_velocity_y`.
`jump_cut_applied` describes the latest launched jump; release eligibility ends
at its relative apex or landing. These are simulation state and are not saved
in scene or prefab JSON. Teleports, geometry changes, disabling, configuration
changes, removal and physics shutdown clear pending releases with other jump
state. Pausing freezes requests and buffering until simulation resumes.

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

## Crouching and safe standing

`crouch_height` is the capsule's local tip-to-tip height while crouched (default
20). It is clamped between the authored capsule diameter and standing height;
radius is unchanged. Zero disables crouching. `crouch_speed` is the horizontal
target speed while crouched (default 100, relative to platform motion); zero
prevents intentional horizontal movement. Acceleration and air control still
apply. Crouching works on the ground and in the air, and does not disable jumps.

Send a held request from your update or fixed-update callback:

```odin
ecs.character_controller_2d_crouch(
    world, player, input.is_down(rune.input_state(game), "move_down"),
)
```

The request persists until replaced. Simulation consumes it on the next fixed
step, so pausing does not resize the character. Shrinking preserves world-space
feet and horizontal position, including reflected and nonuniform scales.
Releasing requests standing; if there is a solid ceiling in the added headroom,
the capsule stays short and retries every fixed step until clear. Boxes, circles,
capsules, polygons and segments participate in the same exact shape query.
Sensors, the character's own colliders, excluded collision layers and one-way
undersides do not block upward growth. Growth uses a 0.005-unit contact tolerance
(or 1% of the radius for very small capsules) to allow resting contact.

`get_character_controller_2d_state` exposes `crouch_requested`, `crouched`,
`stand_blocked`, and the effective local `capsule_height` while crouched.
Use `get_effective_capsule_collider_2d` for live collision dimensions and offset,
for example to size character visuals. Physics queries, ground snapping,
one-way drop clearance and gizmos use this live geometry. The regular
`get_capsule_collider_2d` and serialization retain the authored standing capsule.
Posture changes keep native body and shape identities, velocity, moving-platform
support and drop guards; they do not rebuild the whole body.

Configuration changes clear held requests but retain a short live capsule until
standing passes clearance. Changes to the authored collider, scale, position,
activation, controller removal or physics shutdown reset posture to authored
geometry. Explicit geometry edits and teleports can place a character inside an
obstacle; they are not collision-constrained movement. Unchanged scene values
preserve posture during value reload. Crouch does not add a crush solver for
platforms moving into ceilings.

## Stairs and curb step-up

Set `step_height` to the largest rise the character may step onto, in world
units. It defaults to `0`, preserving ordinary collision behavior. For example:

```json
"CharacterController2D": {"step_height": 18}
```

Step assistance requires grounded horizontal movement input toward an obstacle.
It does not run during a jump, while airborne, or merely because a platform
carries an idle character into a wall. Buffered jumps and drop requests take
priority. Small curbs can be stepped onto even when there is insufficient
headroom to lift by the entire configured maximum.

The motor sweeps the effective capsule upward, forward by this fixed step's
horizontal travel, and down onto a candidate landing. It checks the actual
landing face against `max_slope_angle`, checks the rise against `step_height`,
and verifies the path at the resulting height. This prevents steep slopes from
becoming stairs and stops steps into low ceilings or taller walls. Near a convex
stair edge, the rounded capsule may briefly touch the corner at a steep normal;
the verified top face supplies the support normal for that step. Native movement
must still confirm support afterward.

Only vertical position is adjusted. Box2D advances horizontal velocity once, so
probing ahead adds no horizontal teleport or extra travel. The native body and
shape are retained, and moving-platform velocity is applied through the normal
support logic. Descending stairs continue to use `ground_snap_distance`; this
setting adds upward assistance only.

Crouching uses its shorter live capsule for all clearance checks. Sensors and
excluded layers do not obstruct stepping. One-way sides and undersides remain
passable, and raising a trial capsule does not allow it to acquire a one-way top
from underneath. A character already supported by a one-way platform can step
onto a nearby solid curb. Existing drop guards continue to filter their source.
This remains a small fixed-step controller, not predictive crush avoidance for
platforms moving into walls or ceilings.

The runtime state's `stepped` flag reports assistance in the latest fixed step;
`step_support` and `step_component` identify its candidate landing. Configuration
changes and the usual controller resets clear this state. The ramps demo has
three stairs and a low red bar that requires crouching before stepping further.
Try `set player CharacterController2D.step_height 0` to compare normal collision.

## Wall sliding and jumping

Both features are opt-in and independent:

```json
"CharacterController2D": {
  "wall_slide_speed": 80,
  "wall_jump_speed_x": 260,
  "wall_jump_speed_y": 360,
  "wall_jump_lock_time": 0.18
}
```

`wall_slide_speed` caps downward velocity relative to the wall while airborne
and pressing toward it. Zero (the default) disables sliding. Releasing horizontal
input or steering away restores ordinary falling; the slide limit does not shorten upward jumps.
The normal world fall-speed limit also applies.

Both `wall_jump_speed_x` and `wall_jump_speed_y` must be positive to enable wall
jumping. They default to zero; setting either to zero disables wall jumps without
disabling ground jumps or sliding. The usual jump press launches away from an
eligible wall and upward, adding that wall's current linear velocity. The
inherited velocity is frozen at takeoff and survives removal or reversal of the
wall. Variable-height jump release uses this same takeoff reference.

`wall_jump_lock_time` suspends horizontal steering after launch so inward input
cannot immediately cancel the push. It defaults to 0.15 seconds, accepts 0–1,
and zero gives immediate air control. Gravity and collision response continue
during the lock. Landing ends it early. Another wall jump requires an eligible
wall after the lock expires; held buttons do not generate repeated presses.

Wall eligibility requires input toward a solid, nearly vertical face (normal's
vertical magnitude at most 0.01) within 0.05 world units of the capsule side.
A short ray at the effective capsule center verifies the actual face. This
excludes rounded tip contacts at corners, ceilings, slopes, sensors, excluded
layers, and one-way sides/undersides. Crouched and scaled capsules use their live
geometry. There is no wall coyote window. Ground/coyote jumps take priority;
otherwise the usual jump buffer can wait for wall contact, including buffered
taps and newer presses. Drop-through still takes priority over jump requests.

Runtime state exposes `wall_entity`, `wall_component`, `wall_normal`, and
`wall_velocity` for the currently eligible wall, `wall_sliding` for an applied
slide with continuing contact, `wall_jumped` for a launch in the latest step,
and `wall_jump_lock_remaining`. Resets clear these fields with other motor state;
wall removal, disabling, geometry edits and teleports invalidate wall contact.
These values are not serialized. The ramps example includes a shaft entered
from below: jump toward a wall, then alternate directions and jump presses to
climb. Hold jump for height or release early for a short hop.

## Dashes and chaining

Dashing is disabled by default (`dash_speed = 0`). For three horizontal dashes
per chain, configure:

```json
"CharacterController2D": {
  "dash_speed": 300,
  "dash_duration": 0.14,
  "dash_cooldown": 0.5,
  "dash_chain_count": 3,
  "dash_chain_window": 0.2,
  "dash_on_ground": true,
  "dash_in_air": true,
  "dash_gravity_scale": 0
}
```

Send `ecs.character_controller_2d_dash(world, player, direction)` on each input
press. Direction must be finite and nonzero; its sign selects left or right.
Game code chooses the direction, including remembered facing when standing still.
The API returns false for missing/disabled controllers, disabled dashing, or
invalid directions. True means the request was latched; permission and cooldown
are checked when simulation consumes it. No velocity changes while paused.

A press during a dash queues one next dash. The current segment completes before
the queued one starts on the following fixed step, with no idle step in between.
A later press replaces the queued direction; repeated calls before a step also
coalesce. The queue has one slot, so each additional segment needs another press.
This lets players reverse or redirect successive horizontal dashes without
restarting a dash timer indefinitely. Holding the input button sends no new edge.

`dash_chain_count` includes the first dash (default 1, valid integers 1–32).
After each unfinished chain's segment, `dash_chain_window` gives time to press
again (default 0.15 seconds, range 0–1). A queued dash skips this wait. Zero permits
only chaining requests already queued during the preceding dash. A chain ends
when its limit is reached, its window expires, or a jump/drop cancels it.
`dash_cooldown` then starts (default 0.4 seconds). Presses during cooldown are
discarded, not replayed when it expires. Zero cooldown permits a new chain on
the next press. Landing does not refill or reset a chain or cooldown.

`dash_duration` is positive and at most one second (default 0.15). Durations and
windows use fixed simulation steps; a dash lasts at least one step and rounds
up to whole steps. Each segment rechecks `dash_on_ground` or `dash_in_air` when
it starts, including queued segments. Both default to true. Losing or acquiring
ground does not cancel a segment already underway. A queued segment that fails
its permission check closes the chain and begins recovery.

The dash sets horizontal velocity to its configured speed plus inherited
platform motion. It follows walkable ground slopes, respects the effective
crouched capsule and collision layers, and stops at solid walls/steep obstacles.
It does not invoke stair step-up. One-way sides and sensors stay passable.
Collision ends that segment; the remaining chain/window can still dash away
from the wall. Native collision response and Box2D's world speed ceiling remain
in force; this adds no teleport or invulnerability. After a dash, ordinary motor
acceleration slows its remaining horizontal momentum toward movement input.

While airborne, `dash_gravity_scale = 0` holds vertical velocity at the inherited
platform contribution, making a level dash from stationary ground and replacing
prior jump/fall velocity. Positive values retain vertical momentum and scale
gravity during the dash (`1` uses normal gravity). The fall-speed limit remains
active. Grounded dashes track current support velocity; once airborne, inherited
momentum is frozen and source removal cannot add it again. The dash is horizontal;
there is no vertical aiming or eight-direction mode.

A ground/coyote/wall jump that can launch takes priority over a simultaneous
dash, and cancels an ongoing chain. Accepted drop-through does the same. A dash
start clears old buffered jumps, jump-cut eligibility, and wall-jump steering
lock; jump release cannot shorten a dash. New jump requests during a dash still
use ordinary jump buffering. Wall sliding is suspended during the dash. Crouch
requests and native ceiling collisions continue normally.

Runtime state reports `dashing`, `dash_direction`, `dash_remaining`,
`dash_chain_index` (0 outside a chain), `dash_chain_remaining`,
`dash_cooldown_remaining`, and `dash_queued`. `dash_started`, `dash_ended`, and
`dash_blocked` describe the latest fixed step. Requests and queued directions
are runtime-only too. Configuration changes, teleports, disabling, collider
rebuilds, controller removal and physics shutdown reset all dash state with the
rest of the motor. Unchanged value reload preserves it. Pausing freezes timers.

The ramps example binds Left Shift to dash and remembers facing in its Odin
system. Its HUD displays chain index, queued input, and recovery time. Try
`set player CharacterController2D.dash_chain_count 5` or set `dash_speed` to `0`
to disable the feature.

## Feature controls

All configuration is editable in scene/prefab JSON, through typed setters, and
with `set player CharacterController2D.<field> <value>` in the runtime console.
Gameplay supplies requests in Odin; the controller does not bind keys itself.

| Feature | Tuning / disabling |
| --- | --- |
| Horizontal movement | `move_speed`, `acceleration`; send axis 0 to stop intentional movement |
| Air steering | `air_acceleration`; 0 disables steering |
| Ground/coyote jump | `jump_speed`; 0 disables |
| Short-hop release | `jump_cut_multiplier`; 1 disables, or omit release requests |
| Coyote time / buffering | `coyote_time`, `jump_buffer_time`; 0 disables each grace window |
| Ground snap / step-up | `ground_snap_distance`, `step_height`; 0 disables each assistance |
| Crouching | `crouch_height`, `crouch_speed`; height 0 disables, or omit crouch requests |
| Wall sliding | `wall_slide_speed`; 0 disables |
| Wall jumping | `wall_jump_speed_x`, `wall_jump_speed_y`; either 0 disables |
| Wall-jump steering lock | `wall_jump_lock_time`; 0 disables the lock |
| Dashing | `dash_speed`; 0 disables; `dash_on_ground` / `dash_in_air` permit each start |
| Dash chaining | `dash_chain_count` includes first dash; 1 disables chaining; window and cooldown tune timing |
| Dash gravity | `dash_gravity_scale`; 0 levels airborne dashes, 1 uses normal gravity |
| Slope handling | `max_slope_angle`; 0 allows only flat support |
| Gravity / terminal speed | `gravity`, `max_fall_speed`; both must stay positive |
| One-way collision | `one_way` on the Box/Segment collider; false makes it solid |
| Drop-through | `drop_speed`, `drop_time`; omit drop requests to disable the action |
| Moving-platform carry | Automatic for supporting bodies; there is no separate carry switch |

Configuration edits clear requests and grace state while preserving body
velocity. Game systems should continue supplying current held input. To stop the
entire motor while retaining ordinary physics, remove `CharacterController2D`;
disabling the entity also disables its other systems and physics.

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
periods or wall-jump locks longer than one second, or jump-cut multipliers outside `[0, 1]`.
Dash duration must be in `(0, 1]`, chain window in `[0, 1]`, chain count an integer
in `[1, 32]`, and ground/air permissions boolean. Invalid typed setters and console edits preserve
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

`tools/crouch_2d_validation` checks posture geometry, speed, blocked standing,
automatic retry, reflected scales, collision filtering, moving support,
drop-through and resets. It also runs through `tools/validate.ps1`.

`tools/step_up_2d_validation` checks disabled behavior, repeated stair climbing,
height and slope limits, crouched headroom, slow/fast movement in both directions,
no extra horizontal travel, input/air restrictions, collision filters, moving
supports, one-way support, and runtime disabling. It runs in `tools/validate.ps1`.

`tools/variable_jump_2d_validation` compares tap/partial/full jump heights and
checks release ordering, buffering, expiry, repeated releases, moving-platform
momentum, coyote jumps, drop priority and resets. It runs in `tools/validate.ps1`.

`tools/wall_movement_2d_validation` checks independent feature settings, both wall
directions, steering lock, input edges, filters, corners, moving-wall momentum,
release cutting and contact invalidation. It runs in `tools/validate.ps1`.

`tools/dash_2d_validation` checks chained and reversed dashes, timing/queue limits,
cooldowns, permissions, gravity, collisions, filters, jump/drop priority, moving
platforms, serialization and resets. It runs in `tools/validate.ps1`.
