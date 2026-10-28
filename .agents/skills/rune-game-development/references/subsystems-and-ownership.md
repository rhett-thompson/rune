# Subsystems and runtime ownership

All source and documentation paths below are relative to `RUNE_ROOT`. Read only
the guide needed for the feature; use its current signatures and example rather
than treating this routing table as a second API manual.

| Feature | Read next and key distinction |
| --- | --- |
| Physics, controllers, triggers, interaction | `docs/physics.md`, `docs/character-controller-2d.md`, `docs/character-controller-3d.md`, `docs/triggers-3d.md`, `docs/interactions-3d.md`. Choose the supported body/controller composition; consume physics and trigger events in `post_physics`. See [gameplay-and-scenes.md](gameplay-and-scenes.md) for persistent input commands. |
| 2D navigation | `docs/components.md` (2D navigation workflow), `rune/navigation/grid.odin`, `examples/tanks/tanks_game.odin`. `NavGrid2D`/`NavAgent2D` are settings: game code builds obstacles/clearance, queries paths, and moves entities. |
| 3D navigation | `docs/navigation-3d.md`, `examples/navigation_3d/main.odin`. The scene loop advances agents automatically. Direct Transform movement has no physical collision or gravity; `drive_controller=true` delegates movement to a compatible CharacterController3D. Avoid competing movement writers. |
| Multiplayer | `docs/networking.md`, `examples/relay_multiplayer/README.md`. The relay forwards opaque bytes; a player hosts the simulation. Replication is explicit and does not synchronize arbitrary ECS components automatically. |
| Generated render/collision/navigation geometry | `docs/static-geometry.md`, `docs/navigation-3d.md`, `rune/ecs/static_mesh.odin`, `rune/ecs/navigation_3d.odin`. Distinguish copied, transferred, and borrowed buffers as described below. |
| Memory and storage maintenance | `docs/memory.md`. Reacquire borrowed scene data after compaction even though entity handles remain valid; see [gameplay-and-scenes.md](gameplay-and-scenes.md). |
| Pools and tweening | `rune/pool/pool.odin`, `rune/tween/tween.odin`, `examples/tweening_2d/main.odin`. Game code owns pool lifetimes and advances tweens; attaching scene components does not drive these helpers. |

3D path queries first try a direct X/Z surface trace through connected shared
edges, retaining ramp heights and avoiding triangulation-induced detours when
that route is available. Otherwise ordinary queries use approximate triangle
center-cost A* and funnel smoothing; routes are not guaranteed globally shortest.
Queries wider than the baked inset also enforce extra whole-segment clearance.
Keep the agent's intended radius and height rather than changing its dimensions
to influence route selection. See `docs/navigation-3d.md`.

Inspect the actual path and current baked surface before assuming an agent
should keep a constant heading: an obstacle's baked inset can require a valid
bend even when the endpoints align. For straight ramp cruise, verify a complete
unobstructed route with the agent's authored options before checking facing or
speed; see `tools/navigation_3d_validation/ramp_facing.odin`.

## Service network clients independently of gameplay traffic

Keep calling `network.poll` on the client's owning thread, including when there
are no gameplay packets; it flushes queued messages, sends heartbeats, and detects
timeouts. Choose a callback that continues while menus pause simulation when the
session must stay connected. Wait for membership events before acting as joined.
`network.connect` performs synchronous DNS/TCP setup, so call it outside a
latency-sensitive update. Follow `docs/networking.md` for transport/session
behavior and the example's explicit host/guest replication flow.

## Install generated buffers with the correct owner

`ecs.set_static_mesh` copies input geometry; callers still own their source mesh.
`ecs.set_static_mesh_owned` transfers independently owned persistent vertex/index
buffers on success and zeros the source; failure leaves it unchanged. Do not
transfer borrowed slices or frame scratch, or free aliases after a successful
transfer. Optional collision geometry remains caller-owned and is copied by
native physics. See `docs/static-geometry.md` and `docs/memory.md`.

Use `ecs.set_static_mesh_opacity(world, entity, opacity)` for runtime fades of
installed geometry without rebuilding buffers or changing collision. Finite
values in `[0,1]` multiply per-draw material alpha; replacement resets opacity
to one. Games own timing and cleanup. See `docs/static-geometry.md` for blending
and shadow behavior.

Static-mesh occlusion owns local, world-space, and stable-basis clip face caches;
mesh replacement/removal and bridge shutdown release all three. Current-view
coverage proofs retain the conservative depth and pixel margins. Games may opt
into `Context.occlusion_adaptive_enabled` to budget checks that hide no meshes
or lights: skipped views render fully, useful probes stay active, and scene
changes or stopping after a skipped view force fresh checks. See
`docs/static-geometry.md`.

`ecs.set_navigation_mesh_3d` instead borrows arrays for a `NavMesh3D` configured
with `runtime=true`. Keep those arrays alive and unchanged until the binding is
cleared/replaced, its component/entity is removed, or the World is destroyed.
Unbind with `ecs.clear_navigation_mesh_3d` before freeing them. Update blocked
triangles through `ecs.set_navigation_triangle_blocked_3d` so revisions invalidate
routes; do not mutate the borrowed mesh directly. Runtime mesh bindings are not
serialized, so rebuild/rebind them when a new or restored World needs them.

Terrain detail batches own cached candidate poses, bounded contiguous chunks,
eight-root block bounds, packed source indices, and staging arrays. Camera
movement reuses proven ranges and updates changed GPU prefixes while preserving
exact distance selection and grass fading. Terrain pose or alignment changes
rebuild the caches; successful terrain edits replace the batch. Transparent
materials retain a single ordered draw range. All owned arrays are included in
renderer cache memory estimates and released with the batch. See
`docs/terrain.md` for selection, upload, and timing counters.

## Interpret memory measurements

The console's `memory` command reports known World and asset buffers. R3D has a
separate `r3d_bridge.memory_stats` API. These estimates exclude native allocations
and other unmeasured storage; they are not total process RAM or GPU memory. Use
`docs/memory.md` to interpret each counter and a system/allocator profiler for
total or peak usage.
