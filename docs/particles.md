# Particles

The [particle example](../examples/particles_2d/README.md) shows a fountain,
textured smoke, and a triggered burst on a 960x550 reference canvas. Space emits
a burst, E toggles continuous emitters, and C clears live particles. For canvas
configuration, see [2D resolution policies](display.md).

`ParticleEmitter2D` is a built-in JSON component. The scene loop updates its
particles after gameplay updates and renders them through the active `Camera2D`,
sorted with sprites, tilemaps, and text by `draw_order`. Pause/step applies to
particle simulation. Drawing and captures never advance particle time.

```json
{
  "id": "sparks",
  "components": {
    "Transform": { "position": [320, 240, 0] },
    "ParticleEmitter2D": {
      "max_particles": 512,
      "emitting": true,
      "rate": 100,
      "lifetime": [0.4, 1.2],
      "speed": [80, 200],
      "angle": -90,
      "spread": 40,
      "gravity": [0, 180],
      "start_size": 8,
      "end_size": 0,
      "start_color": [255, 220, 120, 255],
      "end_color": [255, 70, 20, 0],
      "additive": true
    }
  }
}
```

- `rate` is particles per simulation second. `emitting: false` stops continuous
  births while existing particles finish; explicit Odin bursts still work.
- `lifetime` and `speed` are inclusive minimum/maximum ranges in seconds and
  world units per second. `angle` is clockwise degrees from +X (`-90` points
  up). `spread` is the full cone width, from 0 to 360 degrees.
- `gravity` is constant world-space acceleration. Size is diameter in world
  units; size and RGBA color interpolate linearly over each particle's lifetime.
- Omit `texture` or set it to `""` to draw circles. A nonempty project-relative
  texture path draws the full cached texture on a square, with the normal asset
  fallback and texture hot reload. `additive` enables additive blending.
- Transform position follows Rune's current 2D hierarchy conventions; inherited
  Z rotation turns the emission direction. The largest absolute inherited X/Y
  scale multiplies diameter. Speed and gravity stay in world units. Existing
  particles remain in world space when the emitter moves. An emitter without a
  Transform uses its parent pose, or the origin when unparented.

Use `ecs.default_particle_emitter_2d()` for the same defaults as an empty JSON
component. The [component schema](../schemas/components.schema.json) lists every
field, default, and numeric limit.

## Odin controls

Call these from simulation callbacks, such as `start`, `update`, or `fixed_update`:

```odin
// Add an emitter to an existing entity with the built-in component registry.
settings := ecs.default_particle_emitter_2d()
settings.emitting = false
ecs.add(world, rune.component_registry(game), entity, settings)

// Return the number actually emitted; excess births are dropped at capacity.
spawned := ecs.emit_particles_2d(world, entity, 40)
live := ecs.particle_count_2d(world, entity)

// Change settings through the normal validated mutation boundary.
settings, found := ecs.get(world, entity, ecs.ParticleEmitter2D)
if found {
    settings.emitting = true
    settings.rate = 60
    ecs.set(world, entity, settings)
}

ecs.clear_particles_2d(world, entity)
```

`clear_particles_2d` reuses allocated storage and restarts the seeded random
sequence. It does not disable continuous emission. Use `emitting = false` as
well when an effect should remain empty. Emitting returns zero for a missing
emitter or nonpositive count; clearing returns false for a missing emitter.

Every emitter owns a bounded compact particle array, allocated on first emission
and reused thereafter. `max_particles` defaults to 256 and is limited to 65,536;
`rate` is limited to 100,000. These are per-emitter limits. Particles do not create
ECS entities. Rendering is CPU-submitted and intended for modest 2D effects.

## Reload and ownership

Only settings serialize to JSON; ages, positions, random state, and emission
credit are transient. Each particle retains its birth-time motion, gravity,
size, and color settings. Edits to those settings affect subsequent births.
Texture, blending, and draw-order edits affect the whole emitter immediately.
Changing `seed` or `max_particles` clears and releases the particle array.

Value-only scene reloads preserve particles unless one of those reset fields
changes. Structural reloads and scene replacement destroy the old World and
its particles. Component/entity removal releases the emitter's storage.
Invalid JSON or runtime edits leave existing settings and particles intact.
`seed` defaults to 1; zero also uses 1. Repeated bursts after clearing reproduce
the random sequence. Different simulation steps or capacity saturation can
change which births survive; this is not a deterministic replay system.

Custom callback loops call `ecs.update_particles_2d(world, dt)` once per
simulation update, then `render.draw_scene_2d` during drawing. Do not call the
update manually when using the engine-owned scene loop.

For game-owned effects outside the ECS, `rune:particles` exposes `Emitter2D`,
`State`, `defaults`, `valid`, `emit`, `update`, `appearance`, `clear`, and
`destroy`. Start with zero-valued `State`, provide valid settings, then destroy
the state when finished. Do not copy initialized state. Its particle array is
borrowed read-only until the next mutation. Reset/destroy state when changing
capacity or seed, as the ECS integration does. Storage uses the allocator active
on first emission; use a persistent allocator, not a frame scratch allocator.

The 2D implementation supports world-space circles and textured quads,
with linear size/color fades. Particle collision, arbitrary curves, local-space
simulation, 3D billboards, and GPU simulation can be added as needed.

## Code-owned 3D bursts

`rune:particles` also provides allocation-free world-space bursts. A value-only
`Pool3D(capacity)` owns a fixed particle array; it can be copied with its owning
game state and needs no destroy call. These bursts have no ECS component or
automatic engine update. Advance the pool once from simulation and borrow its
live prefix during rendering:

```odin
sparks: particles.Pool3D(128)
settings := particles.Burst3D{
    lifetime={0.25,0.6}, speed={2,5}, spread=160, gravity={0,-5,0},
    start_size=0.12, end_size=0,
    start_color={128,238,255,255}, end_color={28,103,150,0}, seed=131,
}
spawned := particles.emit_burst_3d(&sparks, settings, 18, hit_point, hit_normal)
particles.update_3d(&sparks, dt)

batches := [1]r3d_bridge.Particle3D_Batch{{
    particles=sparks.particles[:sparks.count], material="assets/spark.material.json",
}}
view := r3d_bridge.Scene3D_Settings{particle_batches=batches[:]}
r3d_bridge.draw_scene_ex(&bridge, world, manager, view)
```

Speed is world units per second, lifetime is seconds, and size is diameter.
`spread` is the full cone width in degrees: 0 follows the supplied direction,
180 covers its outward hemisphere, and 360 covers a sphere. Direction is
normalized; invalid directions, settings, and timesteps leave the pool intact.
Each birth keeps its own settings, allowing bursts to overlap. Overflow drops
new births. Expiry compacts the live prefix, so particle indices are temporary.
`clear_3d` empties the pool and restarts the seeded sequence on the next burst.
Skip `update_3d` while gameplay is suspended; drawing never advances particles.

The r3d bridge draws modest bursts as small additive spheres through its depth
tested HDR scene and bloom pass, with no particle entities or shadows. Supply a
lit material with black base color, white emission color, and HDR emission energy
(for example 8). Birth colors tint emission and lifetime alpha fades radiance.
The batch slices are borrowed only during the draw and are never retained.
Particles do not collide with geometry during their motion.

For raylib-only 3D passes, including `render.Overlay3D`, call
`render.draw_particles_3d(pool.particles[:pool.count])` inside the active 3D mode.
It draws additive spheres using birth colors and lifetime fading, respects model
depth without writing particle depth, and never advances the borrowed pool.
The caller owns simulation and the current coordinate transform. This path does
not use R3D materials or bloom.

Run `odin test rune/particles -collection:rune=rune` for 3D burst capacity,
seed replay, directional emission, motion, fading, expiry, and invalid-input
checks. The existing 2D validator below checks the shared random sequence too.

## Example and validation

```powershell
# PowerShell 7 on Windows or Linux
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin build examples/particles_2d -collection:rune=rune "-out:build/particles_2d$exe"
& "./build/particles_2d$exe"
odin build tools/particle_validation -collection:rune=rune "-out:build/particle_validation$exe"
& "./build/particle_validation$exe"
& "./build/particle_validation$exe" --runtime
```

The example shows an additive fountain, textured smoke, and an Odin-triggered
burst. Press Space to burst, E to toggle continuous emission, and C to clear.
Edit its scene JSON while running to tune the effects. The soft particle texture
is an original procedural radial alpha gradient.

The headless validator checks bounded allocation reuse, overflow, lifetime,
gravity, fades, emission timing, seed replay, hierarchy, JSON rejection and
round trips, typed/console edits, reload, and cleanup. `--runtime` adds hidden
window rendering checks. The validator and example are included in
`tools/validate.ps1 -AllExamples`.
