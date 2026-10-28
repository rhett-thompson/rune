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

Every emitter owns a bounded compact particle array, allocated during emission
or owner preparation for potential births and reused thereafter. Preparation
can reserve before the first surviving birth. `max_particles` defaults to 256 and is limited to 65,536;
`rate` is limited to 100,000. These are per-emitter limits. Particles do not create
ECS entities. Rendering is CPU-submitted; worker simulation does not reduce the
cost of submitting each 2D circle or textured quad.

## CPU workers

Project `jobs.worker_count` enables the engine's shared CPU pool. The scene loop
passes it to 2D particle simulation automatically. Large batches run one job per
emitter: the owner resolves enabled entities and composed emitter poses, reserves
all required particle storage, then lends distinct State headers and arrays to
the jobs. The barrier finishes before the owner publishes the State headers back
to the World. Births, random numbers, emission credit and swap/pop expiry retain
the scalar order within each emitter. World maps, transforms and asset/GPU calls
remain on the owner. Small batches use the scalar path.

Current dispatch heuristics require at least two valid 2D emitters with work and
131,072 estimated live/potential-birth operations. Billboard preparation requires
16,384 total input particles across its batches. Those cutoffs reflect isolated
Windows AMD64 and Linux AMD64/WSL2 CPU comparisons, not a promise of faster game
frames. Smaller effects keep the cheaper scalar path. Code-owned 3D integration
can use jobs from 131,072 live particles when a pool is explicitly supplied, but
the measured large 3D workloads regressed on both platforms without a stable
particle-count crossover. Benchmark that stage in the intended scene before
opting in; omitting the pool keeps the original serial pass. Treat the
constants in `rune/particles/particle_jobs.odin`,
`rune/particles/particle_jobs_3d.odin` and `rune/r3d_bridge/particle_jobs.odin` as
internal heuristics rather than game-side configuration or lifetime rules.

Custom loops may pass a borrowed pool to `ecs.update_particles_2d(world, dt,
pool)` once per simulation tick. Code-owned emitters can use
`particles.update_many_2d(work, dt, pool)`, where each
`particles.Update_2D_Work` contains a unique `^particles.State`, settings, origin,
rotation and scale. Keep those states and snapshots alive and exclusively owned
until the call returns. The helper reserves on the calling thread before jobs
write retained arrays; workers do not grow them or adopt their allocators.
Do not submit the same State twice or concurrently emit, clear, destroy or draw
it. A nil pool preserves serial execution. See [CPU jobs](jobs.md) for shared-pool
ownership and synchronous fallback behavior.

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

Custom callback loops call `ecs.update_particles_2d(world, dt, pool)` once per
simulation update, then `render.draw_scene_2d` during drawing. Do not call the
update manually when using the engine-owned scene loop. The trailing pool is
optional; existing two-argument calls remain serial.

For game-owned effects outside the ECS, `rune:particles` exposes `Emitter2D`,
`State`, `defaults`, `valid`, `emit`, `update`, `appearance`, `clear`, and
`destroy`. Start with zero-valued `State`, provide valid settings, then destroy
the state when finished. Do not copy initialized state. Its particle array is
borrowed read-only until the next mutation. Reset/destroy state when changing
capacity or seed, as the ECS integration does. Storage retains the allocator
active when first reserved, during emission or owner preparation for potential
births; use a persistent allocator, not a frame scratch allocator.

The 2D implementation supports world-space circles and textured quads,
with linear size/color fades. Particle collision, arbitrary curves, local-space
simulation, and GPU simulation can be added as needed.

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

Pass `game.worker_pool` as the optional third argument to `update_3d` for large
code-owned pools. `particles.update_3d_slice(live, dt, pool)` provides the same
integration for an exclusively borrowed live slice and returns its new live
count. Jobs integrate disjoint ranges; the owner compacts after joining. The
resulting live prefix exactly matches the scalar swap/pop order, including
mixed expiry. Storage beyond that prefix is unspecified. These helpers allocate
no particle storage and retain no pointers after return. 3D pool simulation stays
game-owned; enabling jobs does not add an automatic 3D particle tick.

The r3d bridge draws modest bursts as small additive spheres through its depth
tested HDR scene and bloom pass, with no particle entities or shadows. Supply a
lit material with black base color, white emission color, and HDR emission energy
(for example 8). Birth colors tint emission and lifetime alpha fades radiance.
The batch slices are borrowed only during the draw and are never retained.
Particles do not collide with geometry during their motion.

For softly lit floating particles, set a batch's `shape=.Billboard` and
`blend=.Alpha`. The bridge draws camera-facing unit quads scaled to the particle
diameters, using a generated radial alpha mask instead of the material's albedo
texture. Material albedo color, lighting, and roughness still apply; particle
color multiplies the material color and particle alpha controls opacity. Use a
nonemissive material for dust, pollen, or snow. Billboards share the HDR scene,
depth testing, and final effects, without writing depth or casting shadows.

```odin
ambient := r3d_bridge.Particle3D_Batch{
    particles=motes[:], material="assets/ambient.material.json",
    shape=.Billboard, blend=.Alpha,
}
```

Each billboard batch uses one instanced draw, with alpha instances sorted from
back to front along the camera's view. Reusable CPU/GPU storage belongs to the
bridge context and grows only when the submitted particle or batch count exceeds
its previous capacity. The radial texture is created once and released at bridge
shutdown. Empty and invisible particles submit no draw; rendering never changes
the borrowed simulation. The default `.Sphere` and `.Additive` behavior remains
suitable for existing glowing bursts.

Forward `worker_pool=game.worker_pool` to `r3d_bridge.init` to enable large
billboard preparation batches. The bridge first gathers all billboard inputs and
reserves their retained CPU arrays on the owner. Jobs classify disjoint input
ranges; a second phase compacts in source order, sorts alpha instances and packs
the position/scale/color streams independently per batch. Both barriers complete
before the owner uploads any instance buffers or submits particle draws. A
single batch's alpha sort stays on one thread. The scalar and worker paths use
the same visibility tests and sort, including tied depths and invalid inputs.
Sphere submission remains on the owner.

`Context.frame_stats` includes `particle_billboards_prepared`,
`particle_prepare_chunks` and `particle_prepare_job_batches`, plus
`particle_prepare_cpu_ms` and `particle_upload_cpu_ms`. Times measure owner
elapsed preparation/barriers and native upload/submission calls; they are not
GPU completion timings. Small batches and a nil pool avoid dispatch. Saturated
pools let the caller finish these synchronous jobs, including when unrelated
callbacks occupy workers. Keep source slices immutable until the draw returns;
the bridge borrows the pool and must shut down before its owner destroys it.

To adjust a batch's self-illumination at runtime, set
`emission_energy_override=true` and `emission_energy` to an absolute HDR energy.
This works for both shapes and changes a local material copy for that draw;
authored material colors and other batches are preserved. Zero disables emission,
negative values clamp to zero, and nonfinite values retain the authored energy.
Leaving the override disabled preserves the material's energy, including for a
zero-valued batch. Particle alpha and sphere radiance fades still apply.

For raylib-only 3D passes, including `render.Overlay3D`, call
`render.draw_particles_3d(pool.particles[:pool.count])` inside the active 3D mode.
It draws additive spheres using birth colors and lifetime fading, respects model
depth without writing particle depth, and never advances the borrowed pool.
The caller owns simulation and the current coordinate transform. This path does
not use R3D materials or bloom.

Run `tools/odin.ps1` / `tools/odin.sh` with `test rune/particles` and the Rune
collection for 3D burst capacity,
seed replay, directional emission, motion, fading, expiry, and invalid-input
checks. Worker tests additionally cover serial parity, mixed expiry, non-owner
execution, caller-only allocation, reservation failure and full/free queues.
The existing 2D validator below checks the shared random sequence too.

## Example and validation

```powershell
# Windows PowerShell; on Linux omit .exe and -linker:msvc, and use ./build/...
New-Item -ItemType Directory -Force build | Out-Null
$exe = '.exe'
./tools/odin.ps1 -OdinArguments @('build','examples/particles_2d','-o:none','-linker:msvc','-collection:rune=rune',"-out:build/particles_2d$exe")
& "./build/particles_2d$exe"
./tools/odin.ps1 -OdinArguments @('build','tools/particle_validation','-linker:msvc','-collection:rune=rune',"-out:build/particle_validation$exe")
& "./build/particle_validation$exe"
& "./build/particle_validation$exe" --runtime
./tools/odin.ps1 -OdinArguments @('build','tools/particle_worker_validation','-linker:msvc','-collection:rune=rune','-collection:r3d=third_party/r3d-odin',"-out:build/particle_worker_validation$exe")
& "./build/particle_worker_validation$exe"
& "./build/particle_worker_validation$exe" --runtime
```

The example shows an additive fountain, textured smoke, and an Odin-triggered
burst. Press Space to burst, E to toggle continuous emission, and C to clear.
Edit its scene JSON while running to tune the effects. The soft particle texture
is an original procedural radial alpha gradient.

The headless validator checks bounded allocation reuse, overflow, lifetime,
gravity, fades, emission timing, seed replay, hierarchy, JSON rejection and
round trips, typed/console edits, reload, and cleanup. `--runtime` adds hidden
window rendering checks. The validator and example are included in
`.\tools\validate.bat --all-examples`.

The separate worker validator checks scalar/worker 2D and 3D simulation, exact
billboard instance streams, tied depths, invisible/nonfinite input filtering,
input immutability, retained allocator reuse and busy full/free queues without a
window. Its `--runtime` branch drives a configured engine scene loop and compares
2D particle states and circle/textured alpha/additive pixels against a scalar
World. It then compares ordinary R3D draw pixels and actual GPU position, scale
and color buffers for three billboard batches, spheres, camera rotation, blend
changes, empty reuse and shared-pool contention. It uses hidden windows but
still requires a graphics context/display.

On 2026-10-28, the worker validator's headless and runtime modes passed on Windows
AMD64 with Odin `84bc3fc`, MSVC, static raylib 6/R3D, GLFW Win32 and an NVIDIA GTX
1060 using OpenGL 3.3. Linux GPU parity remains unverified; CPU worker unit and
benchmark checks do not establish graphics behavior on another platform.
