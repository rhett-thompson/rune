# CharacterController3D

`CharacterController3D` is a reusable fixed-step capsule motor over Box3D's
mover queries. It handles walking, sprinting, acceleration, braking, air control,
gravity, jumping, slopes, ground snapping, stairs, crouching, and moving supports.
Game code supplies movement and jump requests and owns the camera. The
[first-person example](../examples/first_person_3d/README.md) and
[third-person example](../examples/third_person_3d/README.md) demonstrate it with
the same movement course and different camera controls.

## Setup

Put these components on an unparented entity:

```json
"Transform": {"position": [0, 0, 0]},
"CharacterController3D": {
  "radius": 0.35,
  "height": 1.8,
  "crouch_height": 1.0,
  "move_speed": 5,
  "sprint_multiplier": 1.8,
  "crouch_speed": 2.5,
  "acceleration": 35,
  "braking": 45,
  "air_acceleration": 10,
  "gravity": 24,
  "jump_speed": 8,
  "jump_cut_multiplier": 0.5,
  "max_fall_speed": 45,
  "max_slope_angle": 45,
  "ground_snap_distance": 0.2,
  "step_height": 0.3,
  "coyote_time": 0.1,
  "jump_buffer_time": 0.1,
  "push_force": 50
}
```

Every controller field is optional; these are the defaults. `Transform.position`
is the center of the feet, with positive Y pointing up by default. Radius and full capsule
height are world units. The entity must use unit scale and have no parent,
`RigidBody3D`, `BoxCollider`, `SphereCollider`, or legacy `CharacterController`.
The motor stays inactive until this setup is complete. Check
`ecs.character_controller_3d_ready` or the runtime state's `active` field.
Transform rotation does not tilt the capsule; the runtime gravity frame does.

The motor's capsule participates through native queries rather than a rigid
body. It collides with enabled, non-sensor native shapes sharing layer bits.
Rotated boxes, spheres, and static, kinematic, and dynamic bodies are supported.
The capsule itself is not returned by physics ray/overlap queries and does not
produce native contact/sensor events or collide with other query-only characters.
Use its runtime state for grounding and support information.

To test a projectile segment against a query-only character, use
`ecs.character_controller_3d_raycast(world, entity, origin, translation, padding)`.
It respects the current capsule height and gravity frame, reports starting
overlap at fraction zero, and accepts optional nonnegative radius padding.
Compare its hit fraction with `physics_3d_raycast`, or
`physics_3d_sphere_cast(world, origin, translation, radius, filter)` for a finite
projectile, to let nearer world geometry block the shot.

## Controls and timing

```odin
// Supply world X/Z movement, preserving analog strength up to magnitude 1.
ecs.character_controller_3d_move(world, player, direction, sprint)
ecs.character_controller_3d_crouch(world, player, crouch_held)
if jump_pressed {ecs.character_controller_3d_jump(world, player)}
if jump_released {ecs.character_controller_3d_release_jump(world, player)}
```

Movement, sprint, and crouch requests persist until replaced. Send zero movement
when input is released or captured by a menu. Jump press/release requests are
latched until a fixed step consumes them. The functions reject missing/disabled
controllers; movement also rejects nonfinite directions. They return success.

Sample input once per rendered frame before simulation, or from `fixed_update`.
The first-person example uses `ui_update` with a pause check so mouse deltas are
sampled once, while the motor keeps its fixed rate. Standalone callers advance
`ecs.physics_3d_update`; the engine scene loop already does this. Movement runs
after the native world advances on each 1/60-second step, and `post_physics`
callbacks see the result. Pausing the simulation stops the motor.

Keep the camera on a separate entity. For first person, derive its position from
the player's feet plus an eye height based on the effective capsule height.
The example interpolates between `state.previous_position` and the current feet
using the engine's remaining fixed-step fraction. Mouse look runs at the render
rate, and movement uses yaw alone so looking up or down does not change speed.
When rendering moving supports at their current physics poses, interpolate the
camera in that same support frame. Capture the support transform before each
fixed step, map the previous feet through that transform's inverse into the
current support transform, and interpolate from that mapped point to the current
feet. Interpolating world-space feet alone makes an otherwise stationary rider
vibrate relative to the support at render rates different from the physics rate.
The first-person example adds subtle camera-only head bob driven by ground
movement, with configurable amplitude, cadence, smoothing, and an off switch in
its `FirstPersonController` settings. See the [example](../examples/first_person_3d/README.md)
for defaults; no bob is applied to the motor or collider.

## Movement behavior

### Free motion

`ecs.character_controller_3d_set_free_motion(world, player, true, velocity)`
switches to unrestricted world-space velocity in units per second. Fixed steps
move the feet without collision, gravity, ground snapping, or support carry.
Pass zero velocity to hover; games own flight input and speed. Camera interpolation
still uses `previous_position`. Walking configuration is retained unchanged.

Pass `false` to resume the normal motor. Mode changes clear momentum, support,
posture, and jump buffers. The runtime `free_motion` flag and velocity persist
until replaced, and reset on teleport, disable, component removal, or shutdown.
The entity remains enabled for rendering, audio, interactions, and triggers.

### Planetary gravity

Use `ecs.character_controller_3d_move_on_plane(world, player, direction, up, sprint)`
for a world-space `[3]f32` movement direction and an arbitrary up vector. The
function normalizes up, projects movement onto its perpendicular plane, and
clamps movement magnitude to one. It rejects zero/nonfinite up or nonfinite
movement. Call it before each fixed step as the local gravity direction changes.

The capsule, ground probes, slope limits, steps, crouch clearance, jump/cut,
fall-speed limit, pushing, trigger overlap, and debug capsule all use local up.
Gravity magnitude still comes from `CharacterController3D.gravity`; acceleration
points along negative up. Velocity stays in world space across gravity changes.
The runtime state exposes `up`, `world_move`, and `use_world_move`. These commands
persist until replaced and reset on teleport or disable. Calling the original
`character_controller_3d_move` restores the default world-Y frame.

The [Pocket Planets example](../examples/planetary_3d/README.md) shows radial
gravity selection, faceted Box3D mesh terrain, a camera that follows the horizon,
and jumps between gravity wells. Cameras and visuals remain game-owned.

### Ground and air movement

`ecs.character_controller_3d_add_external_velocity(world, entity, velocity)` adds
world-space velocity in units per second for the **next fixed physics step only**.
Use it for currents, wind, and other tangent motion that should combine with
the character's own controls. Multiple requests before that step accumulate.
Submit from `fixed_update` immediately before physics; omit suspended sources.
Requests queued from rendered-frame callbacks apply to only one physics step,
even if that frame runs several steps. Pausing physics leaves an unconsumed
request queued, so submit after checking gameplay suspension.

The motor projects this contribution onto the plane perpendicular to runtime up,
then follows walkable ground at the requested surface speed. It adds the result
after ordinary acceleration/braking and dash selection, using the same capsule
sweeps, sliding, stairs, support carry, and gravity. A dash that ends partway
through a step still receives external motion across the entire step. Effective
motion also drives the existing bounded pushing of dynamic obstacles.

The contribution does not change movement intent, ordinary velocity, jump/fall
speed, or resumed dash momentum. `state.pending_external_velocity` exposes only
the queued request and clears when the step consumes it; refresh the request
each step to keep the effect active. Missing, disabled, invalidly composed, and
free-motion controllers reject requests. Nonfinite vectors, nonfinite sums, and
overflowing vector lengths are rejected without changing the pending request.
Teleport, disable, removal, and free-motion mode changes clear queued motion.

`ecs.character_controller_3d_dash(world, entity, direction, speed, duration)`
starts a finite world-space tangent burst. Direction is projected onto runtime
up and frozen when triggered. The ordinary capsule sweeps, steps, slope limits,
support carry, gravity, and jumps remain active. An active burst rejects another
request; free motion rejects bursts. Games own the input trigger, cooldown, and
whether a burst is allowed from the ground or air.

The runtime state exposes `dashing`, `dash_direction`, `dash_speed`, and
`dash_remaining`. The last partial fixed step consumes only the remaining burst
time, then resumes ordinary movement without retaining dash-speed momentum.
`ecs.character_controller_3d_cancel_dash(world, entity)` immediately clears the
burst and tangent momentum, preserving vertical motion. Also send zero ordinary
movement when a menu blocks input. Teleport, disable, removal, and free-motion
mode changes clear bursts automatically.

Ground movement approaches the requested speed using `acceleration`, or
`braking` when the input is zero. `air_acceleration` controls adjustment in the
air; zero preserves horizontal momentum. Sprint multiplies normal speed;
crouching uses `crouch_speed`. Direction magnitude below 1 retains analog strength.

Walkable surfaces have an upward normal within `max_slope_angle` degrees.
Grounded speed measures distance along the surface. The motor preserves the
requested heading in the plane perpendicular to local up, lifts it onto the
slope, and applies acceleration and braking along that surface. Runtime velocity
retains the full ground tangent, including the slope's rise, between steps.
Downward capsule probes maintain contact
within `ground_snap_distance`; they do not pull a rising jump back to the floor.
Movement sweeps the entire capsule and resolves collision planes to slide along
obstacles, including thin walls. Steep surfaces do not count as jumpable ground.

Stairs require a clear upward sweep, forward movement, and a walkable landing
within `step_height`. A ceiling or tall obstacle blocks the step. Set
`step_height` to zero to disable stepping. Crouching keeps the feet in place;
standing uses a capsule overlap check, including deep overlap, and remains
blocked until there is enough clearance.

`coyote_time` allows jumping shortly after leaving a ledge. `jump_buffer_time`
retains a press made shortly before landing. Both are seconds, with zero disabling
the grace window. Releasing jump early cuts upward speed by
`jump_cut_multiplier`. Holding jump does not automatically jump again on landing.

Moving supports carry the previous contact point through translation and
rotation. Carry is swept against surrounding geometry. Jumping or walking off
inherits support velocity; subsequent changes to that platform do not steer the
airborne character. Removing or disabling the support clears the association.
Grounded motor velocity is relative to the support; airborne velocity includes
the inherited world motion. Takeoff applies the contact-point carry once, and
landing converts velocity back into the new support's frame. Game code must not
add the platform velocity again when requesting a jump.
`push_force` bounds the horizontal force applied to contacted dynamic obstacles;
zero disables pushing. This is one-way character-driven pushing, not a rigid-body
character simulation.

## Runtime state and edits

```odin
state, found := ecs.get_character_controller_3d_state(world, player)
config, configured := ecs.get(world, player, ecs.CharacterController3D)
```

State includes `active`, `grounded`, `ground_normal`, `velocity`, `height`,
`crouched`, `stand_blocked`, `stepped`, `support_entity`, `support_velocity`,
`inherited_velocity`, `previous_position`, and pending requests/grace timers.
`velocity` is the motor velocity before horizontal collision constraints; actual
displacement can be smaller when blocked or include additive external motion
that is deliberately absent from stored motor velocity.
Authored scene JSON contains controller settings. Movement state is runtime-only.
Use `ecs.set` or `ecs.set_character_controller_3d` for configuration edits.
JSON, prefab loading, console field edits, and value-only scene reloads use the
same validation. Value-only edits preserve movement state; full World replacement
starts fresh. Disabling/removing the component clears requests and state.
Authored position/scale changes clear state so teleports do not preserve a queued
jump or stale support. Spawn and teleport into clear space: native mover plane
queries do not recover arbitrary deep overlap inside solid hulls.

All values must be finite and nonnegative. Radius, acceleration, braking,
gravity, and maximum fall speed must be positive. Heights must satisfy
`2 * radius <= crouch_height <= height`; step height must be below standing
height. Sprint multiplier is at least 1, slope is below 89 degrees, and jump-cut,
coyote, and buffer values are at most 1. The schema provides field completion;
the runtime also enforces relationships between fields.

F3 physics gizmos show the effective capsule and ground normal. The first-person
example displays grounded, crouched, and blocked-standing state.

## Local validation

From the repository root on Windows:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = '.exe'
odin run tools/character_controller_3d_validation -linker:msvc -collection:rune=rune "-out:build/character_controller_3d_validation$exe"
```

This opens no window and exercises the real Box3D backend: grounding, walls,
sliding, jumps, ramps, stairs, crouch clearance, moving platforms, dynamic-body
pushing, filtering, fast casts, fixed-step timing, configuration, scene reloads,
and lifecycle resets. It is also discovered by `.\tools\validate.bat`.

The older `CharacterController` / `ecs.move_character` remains available for
existing projects. Both the first- and third-person examples use the new motor;
their camera controls and character visuals remain game-owned.
