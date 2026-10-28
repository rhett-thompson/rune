# Skeletal animation

Rune uses R3D's skeletons, animation libraries, players, and GPU skinning.
Add `ModelAnimator` beside `ModelRenderer` to play a clip embedded in a model:

```json
{
  "ModelRenderer": { "model": "assets/character.glb" },
  "ModelAnimator": {
    "clip": "walk",
    "events": "assets/character.model-events.json",
    "speed": 1,
    "loop": true,
    "autoplay": true
  }
}
```

`clip` is case-sensitive; an empty name selects the first imported clip.
`speed` must be finite and nonzero. Negative speed plays in reverse.
`events` is optional and defaults to an empty path; see
[skeletal animation events](model-animation-events.md). The other fields default
to the values shown above.

The R3D bridge remains optional. Register a simulation update callback which
calls `update_animations` once, and draw through the existing bridge:

```odin
update :: proc(game: ^rune.Engine, world: ^ecs.World) {
    r3d_bridge.update_animations(&bridge, world, rune.asset_manager(game), game.delta_time)
}

draw :: proc(game: ^rune.Engine, world: ^ecs.World) {
    r3d_bridge.draw_scene(&bridge, world, rune.asset_manager(game))
}
```

Initialize and shut down the bridge while the raylib graphics context is alive,
as in the [skeletal_animation_3d example](../examples/skeletal_animation_3d/main.odin).
Drawing prepares a pose without advancing time or publishing simulation state.
Engine pause/step therefore applies to animation too. Repeated draw calls and
captures preserve the simulation state.

## CPU pose jobs

Enable the optional project `jobs.worker_count` and pass
`worker_pool = game.worker_pool` to `r3d_bridge.init` to allow parallel pose
evaluation across characters. The default has no pool; small workloads and
unavailable queue capacity use the calling thread. This changes scheduling,
not playback timing, marker order, or when the pose becomes available.
The bridge selects the parallel path only when at least two players need a new
pose and their skeletons total at least 2048 bones. Players whose cached pose
can be reused do not count toward this threshold. Dispatch overhead varies by
workload and platform; see the [animation worker benchmark](../tools/animation_worker_benchmark/README.md).

The bridge finishes model and animation-library reloads before gathering pose
work. The owner advances timelines, publishes events, and prepares each player.
Workers compute that player's local pose, optional blend, and model-space pose
using its private buffers and shared read-only skeleton/clip data. Each batch
joins before the owner uploads skin textures, releases finished blend storage,
and publishes evaluated players to its cache. Playback state and marker events
are updated on the owner during gathering. GPU creation, upload and destruction,
imports, asset diagnostics, and World mutation stay on the owner.

Keep the borrowed pool alive until bridge shutdown. Do not update the same
bridge concurrently, or mutate a borrowed `animation_player` while the bridge
is preparing poses. Custom R3D trees and arbitrary native animation entrypoints
are outside this worker boundary. See [CPU jobs](jobs.md) for queue and
allocator ownership.

`Context.animation_stats` describes the most recent pose preparation:
`players_evaluated`, `bones_evaluated`, `job_batches`, `pose_cpu_ms`, and
`upload_cpu_ms`. Drawing also prepares poses and resets these values, so inspect
update statistics before the next draw when measuring simulation work.
`pose_cpu_ms` includes the CPU batch barrier; `upload_cpu_ms` covers the owner
upload/cleanup/cache-commit loop. These are elapsed owner timings, not summed
worker time, GPU execution time, or a guaranteed frame-rate improvement.
`job_batches` counts selection of the parallel
batch path; a saturated pool can still leave all work on the calling thread.

## Playback controls

All controls take `world` and `entity` first. Mutating controls return a success
bool; `get_model_animation_state` returns the state and a found flag:

| ECS function | Behavior |
| --- | --- |
| `play_model_animation(world, entity, clip, restart = true)` | Select a clip and play; restart begins at the end for reverse playback. |
| `pause_model_animation(world, entity)` | Keep the current pose. |
| `resume_model_animation(world, entity)` | Continue from the current time. |
| `stop_model_animation(world, entity)` | Stop and seek to time zero. |
| `seek_model_animation(world, entity, seconds)` | Set a nonnegative time, clamped to the clip duration when synchronized. |
| `get_model_animation_state(world, entity)` | Return state and a found flag. |

State includes `elapsed` and `duration` in seconds, `playing`, `finished`,
and `initialized`. A non-looping clip holds its final pose. Rune advances the
playback clock and marker events together; R3D evaluates the resulting pose.
A finished clip can be restarted with `play_model_animation`.

Use `ecs.get(world, entity, ecs.ModelAnimator)` and `ecs.set` for typed
configuration edits. Changing speed or loop preserves playback time; changing
clip or autoplay resets playback state. Scene JSON, prefabs, value reloads,
runtime console inspection, and `set left ModelAnimator.speed 0.5` use the same
component registration and mutation path. Playback controls never save files.

## Assets and lifetime

On Windows/Linux AMD64, Rune's bridge imports FBX files with pivot transforms
folded into their skeleton joints, preserving animation channels that the
upstream importer drops. File, memory, and reload paths use the same setting;
see the [native importer patch](../third_party/r3d-importer/README.md).

Entities share the imported model and animation library, but each has its own
R3D animation player, pose buffers, and skin texture. Instances can play
different clips or speeds without changing each other.

Model timestamp polling uses the existing asset manager. A successful model
reload releases referencing players before freeing the old library/skeleton;
players are recreated on the new data, preserving elapsed time where possible.
A failed reload retains the previous model and animation data. Entity or
component removal is reconciled on the next bridge update/draw. Full scene
replacement releases players from the old world generation.

Unknown clips or models without compatible skeletal animations produce asset
diagnostics and use the static model rendering path. Failed animation imports
are retried when the model revision changes, rather than on every frame.

`r3d_bridge.animation_clips(&bridge, manager, model_path)` returns clip names
copied into frame scratch. `r3d_bridge.animation_player(&bridge, entity)`
returns a borrowed native player and readiness flag for inspection. Its lifetime
ends on removal, reload, or bridge shutdown; Rune owns and updates that player.
Custom R3D animation trees require a game-owned update/draw path; this
component drives a single-clip player.

Rune plays embedded clips and supports pose blends through
`ecs.transition_model_animation` and `ModelAnimator.blend_time`; see
[animation transitions](animation-transitions.md) for interruption and pause behavior.

On Windows/Linux AMD64, register the first clip of a separate animation file
against an existing model, using a unique alias:

```odin
r3d_bridge.register_model_animation_source(
    &bridge, "../assets/Strut Walking.fbx", "punch", "../assets/Punching.fbx",
)
```

Register after bridge initialization, before the first animation update. Then
select `punch` with the normal playback/transition controls. Sources may omit
meshes and skin; their joint names, rest pose, and units must match the model.
This maps joint names, rather than retargeting an animation to a different rig.
Extra unweighted joints are ignored. Registered aliases survive scene and model
reloads; source files are watched, and invalid replacements retain the previous
working animation library. Registration is idempotent for the same model,
alias, and path. Tracks remain shared across instances of that model.

Animation trees and root-motion application are not exposed through Rune
components; R3D remains available for those advanced uses.

## Example and checks

```powershell
# Windows PowerShell
New-Item -ItemType Directory -Force build | Out-Null
./tools/odin.ps1 -OdinArguments @('build', 'examples/skeletal_animation_3d', '-o:none', '-collection:rune=rune', '-linker:msvc', '-collection:r3d=third_party/r3d-odin', '-out:build/skeletal_animation_3d.exe')
./build/skeletal_animation_3d.exe
./tools/odin.ps1 -OdinArguments @('build', 'tools/model_animation_validation', '-collection:rune=rune', '-linker:msvc', '-collection:r3d=third_party/r3d-odin', '-out:build/model_animation_validation.exe')
./build/model_animation_validation.exe --runtime
```

On Linux use `sh tools/odin.sh build ...` with the same collections, omit
`-linker:msvc` and the `.exe` suffix, then run `./build/model_animation_validation --runtime`.

The example shows three instances of an original two-joint glTF model alongside
a looping Strut Walking character loaded directly from the shared FBX asset.
The character uses its embedded `mixamo.com` clip and a `0.01` scene scale.
Space blends into a one-shot punch from the animation-only `Punching.fbx`,
then returns to walking; another press restarts the punch.
Press
1/2 to switch the left instance's clip, P to pause it, and R to resume it.
Its checked-in model can be regenerated from the repository root with
`.\examples\skeletal_animation_3d\generate_fixture.bat` on Windows or
`sh examples/skeletal_animation_3d/generate_fixture.sh` on Linux.
S cycles playback speed, V reverses direction, and H silently seeks to one
second. The left rig's JSON marker tracks trigger sounds and visible effects;
`clip_events` in the runtime console returns their counters.

The normal validator checks component, serialization, control, and scene-reload
behavior without opening a window. `--runtime` additionally uses a hidden
graphics window to verify native playback, independent players, draw stability,
reverse/end behavior, and resource replacement.
It also runs the worker suite; `--runtime-jobs` selects that suite alone.
The worker checks compare serial/parallel poses and rendered results, preserve
timeline/event behavior, and exercise resource reload and shared-pool contention.

On 2026-10-28, both runtime modes passed on Windows AMD64 with Odin `84bc3fc`,
MSVC, GLFW Win32, static raylib 6/R3D, and an NVIDIA GTX 1060 using OpenGL 3.3.
The worker fixture compares 48 actors and 2496 bones at 20 checkpoints, including
exact playback/event/native-pose results and actual RGBA16F skin-texture
readbacks. Checks also cover ordinary crowd draws, paused draws, reverse/end
poses, blends, model/external-clip reloads, removal and World replacement.
Full-queue and occupied-worker/free-queue cases return before watchdogs release
unrelated gated callbacks.

The benchmark above isolates local/blended/model CPU evaluation. Its native
concurrency probes pass on Windows AMD64 and Linux AMD64 under WSL2; they do
not exercise GPU upload, graphics contexts, or full game frame time. Linux
scheduler and CPU benchmark checks passed; Linux GPU behavior remains unverified.
