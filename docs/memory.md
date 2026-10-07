# Memory diagnostics and maintenance

Rune exposes on-demand snapshots through `ecs.memory_stats(&world)`,
`assets.memory_stats(&manager)`, and `r3d_bridge.memory_stats(&renderer)`.
The runtime console's `memory` command returns World and asset snapshots.
Renderer diagnostics remain a separate API so the core does not depend on R3D.

These reports describe known backing buffers, not total process RAM or VRAM.
World maps include their allocated hash-table capacity, including nested
component maps and authored-baseline indexes. `owned_json_bytes` includes the
owned JSON trees' map/array buffers, keys, and strings. `typed_value_bytes`
counts compact custom values; `typed_arenas` reports reference-bearing values.
`static_mesh_bytes` counts retained CPU vertex/index capacity. Hierarchy arrays
are counted separately. Subsystem-owned nested buffers, native Box2D/Box3D
allocations, allocator overhead, and transient generation scratch are excluded.

Arena reports distinguish normal block capacity, out-of-band allocation sizes,
and bookkeeping arrays. When the backing allocator cannot report an allocation
size, `unknown_out_band_allocations` records the missing measurements. Such a
report is incomplete; do not treat its known byte counts as a total.

Asset texture estimates include mipmaps and font/generated ORM textures.
Renderer estimates cover mesh capacities and active/pooled instance buffers.
They exclude backend render targets, shadow maps, imported model textures,
shaders, driver overhead, and GPU allocator slack. Asset reports count cache
entries and cache-map storage, but do not measure all decoded asset data.
Sample snapshots around region generation, installation, and destruction to
compare retained memory; use an allocator or system profiler for total/peak use.

## Reclaiming runtime storage

`add_component` (including typed `add`) clones input JSON into independently
owned storage. Successful replacement and removal release the previous tree;
failed replacement retains it. Named instance removal releases that instance's
owned JSON. Borrowed `get_component` and `get_component_instance` values expire
on replacement/removal, compaction, reload, or World destruction. Clone a value
if it needs to outlive those operations. Custom typed values keep their existing
ownership rules and allocation-free update path for plain structs.

Scene/root JSON, authored hot-reload baselines, interned metadata strings, and
some built-in reference data still use a scene arena. Reclaim unreachable arena
data explicitly with `ecs.compact_scene_storage(&world)` at a safe point, such
as after unloading a region. This rehomes live data and the authored baseline
before releasing the old arena. It also rebuilds the scene/component indexes
that it rehomes, reducing retained map capacity after entity churn.

Compaction invalidates borrowed scene JSON, built-in strings, metadata, and
references into the rebuilt maps. Reacquire those values afterward. Entity
handles, custom typed values, resource pointers, static mesh buffers, native
physics state, and change versions remain valid. Custom/resource data must
follow its ownership contract and must not contain unowned pointers into scene
storage. Compaction temporarily holds both old and new scene storage and can
cause a pause; it is not automatic during gameplay. It preserves the authored
baseline so unchanged disk fields still preserve runtime edits on hot reload.

## Acknowledging component changes

`ecs.prune_component_changes(&world, through_version)` discards acknowledged
records for components that no longer exist. Records for live components remain
available to internal navigation/interaction caches. Acknowledge only after
all interested consumers have processed changes through that version.

`ecs.changes_since_checked(&world, ComponentType, cursor)` returns changes and
a `complete` flag. If false, rescan current membership and establish a fresh
cursor with `ecs.change_version(&world)`. The existing `changes_since` API
remains available for consumers whose cursor is always current. Pruning is
explicit; Rune does not expire records underneath existing consumers.

```odin
// After all systems have consumed removal notifications for unloaded content:
assert(ecs.prune_component_changes(&world, ecs.change_version(&world)))
assert(ecs.compact_scene_storage(&world))
stats := ecs.memory_stats(&world)
```

## Moving generated meshes

`ecs.set_static_mesh_owned(&world, entity, &mesh, collision, collidable)` moves
independently owned, persistent vertex/index buffers into World storage.
Success zeros `mesh`; failure leaves the source and installed mesh unchanged.
Both arrays must own their allocations, not borrow a subrange or frame scratch.
All aliases into a successfully transferred mesh become World-owned and must
not be modified or destroyed by the caller. Borrowed installed buffers cannot
be transferred again. The optional collision mesh remains caller-owned and
Box3D copies it, including when it is the same mesh being transferred.

The existing `set_static_mesh` API still copies inputs. Both paths retain CPU
render geometry, install the same collision, and use the existing GPU resource
lifecycle. Transfer avoids an extra CPU copy; it does not remove necessary
render/collision representations. Asset eviction and dense ECS storage are
separate future changes; this maintenance API does not unload cached assets.

Run the headless lifetime/memory regression checks with:

```powershell
odin run tools/memory_validation -collection:rune=rune -out:build/memory_validation.exe
odin test rune/r3d_bridge -collection:rune=rune -collection:r3d=third_party/r3d-odin -out:build/r3d_bridge_test.exe
```
