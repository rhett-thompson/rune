# 2D particles

The example now uses a 960x550 reference canvas. Keys 1/2/3 select fit, stretch,
and integer scaling; F11 toggles borderless. Effects and labels share the canvas.
See [2D resolution policies](display.md).

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

This initial implementation supports 2D world-space circles and textured quads,
with linear size/color fades. Particle collision, arbitrary curves, local-space
simulation, 3D billboards, and GPU simulation can be added as needed.

## Example and validation

```powershell
odin build examples/particles_2d -collection:rune=rune -out:build/particles_2d.exe
./build/particles_2d.exe
odin build tools/particle_validation -collection:rune=rune -out:build/particle_validation.exe
./build/particle_validation.exe
./build/particle_validation.exe --runtime
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
