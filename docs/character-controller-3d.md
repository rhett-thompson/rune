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
is the center of the feet, with positive Y pointing up. Radius and full capsule
height are world units. The entity must use unit scale and have no parent,
`RigidBody3D`, `BoxCollider`, `SphereCollider`, or legacy `CharacterController`.
The motor stays inactive until this setup is complete. Check
`ecs.character_controller_3d_ready` or the runtime state's `active` field.
Transform rotation does not tilt the upright capsule.

The motor's capsule participates through native queries rather than a rigid
body. It collides with enabled, non-sensor native shapes sharing layer bits.
Rotated boxes, spheres, and static, kinematic, and dynamic bodies are supported.
The capsule itself is not returned by physics ray/overlap queries and does not
produce native contact/sensor events or collide with other query-only characters.
Use its runtime state for grounding and support information.

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
The first-person example adds subtle camera-only head bob driven by ground
movement, with configurable amplitude, cadence, smoothing, and an off switch in
its `FirstPersonController` settings. See the [example](../examples/first_person_3d/README.md)
for defaults; no bob is applied to the motor or collider.

## Movement behavior

Ground movement approaches the requested speed using `acceleration`, or
`braking` when the input is zero. `air_acceleration` controls adjustment in the
air; zero preserves horizontal momentum. Sprint multiplies normal speed;
crouching uses `crouch_speed`. Direction magnitude below 1 retains analog strength.

Walkable surfaces have an upward normal within `max_slope_angle` degrees.
Grounded movement follows the slope. Downward capsule probes maintain contact
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
displacement can be smaller when blocked.
Configuration and runtime state are separate; scene saves serialize settings.
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

From the repository root in PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run tools/character_controller_3d_validation -collection:rune=rune "-out:build/character_controller_3d_validation$exe"
```

This opens no window and exercises the real Box3D backend: grounding, walls,
sliding, jumps, ramps, stairs, crouch clearance, moving platforms, dynamic-body
pushing, filtering, fast casts, fixed-step timing, configuration, scene reloads,
and lifecycle resets. It is also discovered by `tools/validate.ps1`.

The older `CharacterController` / `ecs.move_character` remains available for
existing projects. Both the first- and third-person examples use the new motor;
their camera controls and character visuals remain game-owned.
