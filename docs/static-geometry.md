# Runtime static geometry

`rune:geometry` provides finite voxel surface extraction. A `Volume` contains
X-contiguous `[]u8` cells, dimensions, spacing, and origin. Zero is air; other
values index a caller-provided RGBA palette. `fill_box` fills half-open bounds.
`surface` emits outward triangles and greedily merges coplanar faces of the
same color index. Solid/solid boundaries are omitted. The caller owns the
returned `Mesh`; release it with `geometry.destroy_mesh`.

`append_tube(&mesh, points, radius, sides=8, color={255,255,255,255})` adds a
capped circular tube along a caller-sampled `[][3]f32` path. Side rings follow
averaged path tangents and retain smooth normals; endpoint caps have separate
flat normals. Callers choose curves, spacing, layout, materials, and collision.
Multiple calls append independent paths to one mesh. The function returns false
without changing existing buffers for invalid/nonfinite inputs, consecutive
duplicate points, reversals, collapsed or folded triangles, or mesh limits.
It accepts 2–65,536 points and 3–64 sides. Choose a radius small enough for the
path's bends; open paths and gentle sampled curves work best.

`surface_chunks(volume, colors, chunk_size)` emits independent meshes in
deterministic Z/Y/X order. Chunk sizes are positive voxel counts, anchored at
volume index zero. Each `Mesh_Chunk` carries its coordinate and half-open voxel
bounds; mesh positions retain the volume origin and spacing. Empty chunks are
omitted. Exposed faces merge within each chunk, with neighbor samples from the
whole volume. Cuts through solid cells produce no internal faces or overlapping
caps. Release the owned array and meshes with `destroy_mesh_chunks(&chunks)`.
The volume is validated once; at most 65,536 logical chunks are accepted.
Games choose chunk dimensions, material partitions, metadata, and activation.
Each result can use the existing static-mesh API independently.

`ecs.set_static_mesh(world, entity, mesh)` copies validated vertex/index data
and installs static triangle collision. An entity needs a `Transform` with
positive scale and cannot also own Terrain, a native 3D collider/body, or a
character controller. Positions are welded for Box3D edge identification;
render normals/colors remain split. Physics rays and overlaps report component
`StaticMesh`, and CharacterController3D collides with the surface. Effective
activation, positive transform scaling, rotation, parent transforms, and layer
filters follow the terrain transform rules. Queries synchronize these edits
without advancing simulation. Invalid mesh replacements retain the old data.

Pass an optional fourth argument, `&collision_mesh`, to install simplified
collision while retaining the original render mesh. Both meshes are validated
before replacement. Render vertices/indices are copied into World storage;
Box3D copies the collision geometry into its native mesh. The caller may edit or
destroy either input after installation. Rays, overlaps, and character movement
use the supplied collision surface, while the bridge draws the original mesh.
Omitting this argument preserves the shared render/collision behavior.

Use `ecs.set_static_mesh(world, entity, mesh, collidable=false)` for render-only
surfaces. This copies and uploads the same mesh data but creates no Box3D mesh
or body, so rays, overlaps, and character movement ignore it. Replacing a
collidable mesh with render-only data removes the previous body; replacing it
again with the default options restores collision. A collision mesh cannot be
supplied together with `collidable=false`. Transform and component ownership
restrictions still apply.

The R3D bridge uploads meshes automatically when drawing a World. It owns GPU
copies keyed by entity and revision; deletion, replacement, World changes,
and bridge shutdown release them. World/entity destruction releases CPU and
Box3D mesh resources. `ecs.remove_static_mesh` releases just the runtime mesh.

For temporary generated meshes, `ecs.set_static_mesh_owned(world, entity,
&mesh)` transfers the CPU vertex/index allocations into the World. Success
zeros `mesh`; failure preserves it and the installed mesh. Optional collision
and `collidable` arguments have the same behavior as the copying API. Supply
independently owned, persistent buffers, and relinquish all aliases on success.
See [memory maintenance](memory.md) for ownership and diagnostics details.

Add a `MeshRenderer` with `primitive: "static"` to style installed runtime
geometry. Its `material`, RGBA fallback `color`, and `shadows` switch use the same
material cache and hot reload as primitive meshes. Vertex colors multiply the
material color. Without this component, runtime meshes retain the default
material and cast shadows. The `static` primitive draws no extra geometry.
The bridge supplies dominant-axis planar UVs (one repeat per four local units)
and tangents, including vertical projection on walls for normal maps.

For an existing entity with a Transform and a caller-owned `geometry.Mesh`,
install the material component and runtime geometry through the usual APIs:

```odin
assert(ecs.add(&world, &registry, entity, ecs.MeshRenderer{
    primitive = "static",
    material = "assets/materials/concrete.material.json",
    color = {255,255,255,255},
    shadows = true,
}))
assert(ecs.set_static_mesh(&world, entity, mesh))
```

The renderer's `color` is used when no material loads; it does not tint a
successfully loaded material. Use material `base_color` or mesh vertex colors
for that. Material edits reuse the installed mesh and collision body. The
`MeshRenderer` can be serialized, but `primitive: "static"` alone creates no
surface: the game still installs the runtime mesh after loading the scene.

These meshes are runtime data, not serialized scene components. Recreate them
from game-owned data after scene reload. This API does not generate gameplay
meaning, navigation graphs, or scene JSON.

The bridge caches world transforms, draw matrices, and transformed bounds.
Shared ancestors are checked once per draw; transform, parenting, activation,
mesh replacement, and World changes update the cache automatically. Static
meshes sharing an immediate parent form a render cluster, so a game can group
material meshes under one chunk entity. Unparented meshes form individual
clusters. Bounds include only enabled meshes with valid positive scales.

R3D tests cluster bounds against both the camera and shadow frustums. The bridge
also skips camera-hidden clusters before submission when they cannot cast
shadows (or `Context.shadows_disabled` is set). Off-camera casters remain
submitted to preserve shadows on visible surfaces. This is frustum culling;
walls hiding an in-frustum object do not suppress it unless occlusion is enabled.

Set `Context.occlusion_enabled=true` to enable conservative CPU occlusion for
runtime static meshes. Actual opaque mesh triangles and exactly adjacent convex
planar triangle pairs provide the blockers. Their filled bounding boxes never
act as blockers, so doors and gaps remain open. Up to 32 large faces per mesh
and 128 large projected blockers bound the work. A mesh is hidden only when its
entire projected bounds fit strictly inside one blocker and its nearest depth
is behind the blocker's farthest depth, with extra depth and pixel margins.
This intentionally retains meshes when several surfaces jointly hide them.

Transparent/alpha-textured surfaces, billboards, and custom surface shaders do
not supply blockers. Billboards and custom shaders also remain in the scene.
Near-plane intersections and uncertain coverage fail open. Hidden shadow
casters use R3D's shadow-only mode; hidden non-casters skip submission.
Occlusion affects rendering, not activation, collision, or gameplay queries.
Cache decisions are refreshed when the view, resolution, transforms, hierarchy,
activation, mesh geometry, or material eligibility changes. Rune leaves this
feature off by default. Games performing independent probe captures should
disable camera-specific occlusion during those captures.

The same switch occlusion-culls point and spot lights only when their entire
range sphere's bounding box is hidden. Hiding the source alone never disables
lighting: it may still illuminate a visible surface. Spotlights conservatively
use the full range sphere rather than their narrower cone. Directional lights
remain active. Rejected local lights skip R3D lighting and shadow-map work for
that view; manual/interval shadow maps refresh when the light returns.
Positions and ranges are tested every draw, even when static visibility is
cached. R3D also independently frustum-culls local light influence volumes.

`Context.frame_stats` reports the last draw's CPU wall timings, static uploads,
matrix/bounds rebuilds, cluster tests, skipped meshes, and submitted meshes and
triangles. Submission counts precede R3D's per-camera/per-shadow culling; they
are not actual GPU draw counts. `scene_cpu_ms` includes all bridge scene work,
`static_cpu_ms` covers static grouping/submission, and `backend_cpu_ms` covers
`R3D_End`. These timings do not measure GPU execution or presentation.
Set `Context.static_optimizations_disabled=true` to compare against per-mesh
hierarchy resolution and submission without clusters or early rejection.
Occlusion adds `occlusion_cpu_ms`, `occlusion_tests`, `occlusion_occluders`,
`occlusion_cache_reused`, `static_meshes_occluded`, `static_shadow_only`, and
`static_scene_triangles_avoided`. Shadow-only triangles remain included in the
submitted triangle count; the avoided counter describes main-scene work.
`local_lights` counts synchronized active local lights before backend frustum
culling. `local_lights_occluded` and `local_shadow_lights_occluded` report
rejected lights and the subset with enabled shadow maps. `light_occlusion_tests`
and `light_occlusion_cpu_ms` report the light-volume test work.

The bridge also caches primitive/model render lists in hierarchy order, keeping
planes before other objects. Only renderable entities and their ancestors need
transform snapshots on stable frames; unchanged matrices are reused. Renderer
membership/primitive edits, activation, reparenting, and world replacement are
observed automatically. Authored materials use the asset manager's revision to
reuse resolved R3D materials without hashing the full settings on every draw;
inline material data still receives a signature check. Material and texture hot
reloads invalidate the shortcut.

Light properties are sent to R3D only when their authored values change.
Stationary lights retain activation, allowing manual and interval shadow modes
to work as configured. Continuous maps still update each frame. Games using
manual shadows must request a refresh after moving a light or its casters.

`Context.render_optimizations_disabled=true` restores the original two hierarchy
walks, per-draw material signatures, and light synchronization/activation for
profiling. It is independent of the static mesh/occlusion switches. Additional
counters report `render_entities`, `render_list_rebuilds`,
`render_transform_nodes`, `render_matrices_rebuilt`, `material_requests`,
`material_hashes`, `material_cache_hits`, and `light_properties_updated`.
The light property count excludes activation and shadow-profile synchronization.

Set `Context.instancing_enabled=true` to batch compatible repeated primitives
and static models. Batches share the native mesh, resolved material, scale,
render pass, and a 32-meter spatial cell. Each batch supplies a world bounds
cluster for camera and shadow frustum culling, including off-camera casters.
Common scale remains in the mesh transform so nonuniform normal transforms
retain their lighting behavior. Position/rotation streams upload only when a
batch changes. Stable frames also reuse resolved batch membership; authored
renderer edits, poses, activation, model/material revisions, and manager or
world replacement invalidate it. Transparent materials, billboards, custom
shaders, animated or skinned models, nonstandard depth/stencil settings, invalid/negative scales,
and oversized meshes retain individual submissions. Singleton batches also
draw individually. `render_optimizations_disabled` bypasses instancing.

Instance buffers are pooled across membership/material changes and scene
replacement, grown in place, and released at bridge shutdown. This also avoids
R3D's stale cached VAO bindings when OpenGL reuses a deleted buffer ID. Pool
storage retains its high-water mark. CPU batch arrays are released when no
longer used. Counters include `prop_draws`, `instanced_batches`,
`prop_instances`, `prop_draws_avoided`, and `instance_uploads` (changed batches,
each uploading position and rotation). These count bridge mesh submissions,
including model submeshes, before backend culling and passes.
`prop_batches_reused` reports reuse of resolved membership on that frame.

Set `Context.gpu_timing_enabled=true` to collect asynchronous OpenGL timestamp
queries around `R3D_End`. `gpu_backend_ms` measures the whole queued 3D pipeline:
shadows, scene rendering, volumetric clouds, postprocessing, and final blit.
It excludes game UI and presentation and does not separate individual passes.
Compare feature toggles at the same camera to estimate their contribution.
The eight-slot query ring never reads unavailable results or waits for the GPU;
it skips samples when full. `gpu_supported` reports query availability,
`gpu_ready` reports whether a result has arrived, and `gpu_sample_frame`,
`gpu_sample_age_frames`, and `gpu_samples` describe the delayed result. Query
objects are released at bridge shutdown. Both instancing and GPU timing are
opt-in in Rune. `Context.cloud_volumes_disabled` skips cloud preparation and
drawing without removing entities, for rendering comparisons.

Run the headless ownership/collision validator (also discovered by
`.\tools\validate.bat`) from the Rune root:

```powershell
odin run tools/static_mesh_validation -linker:msvc -collection:rune=rune -out:build/static_mesh_validation.exe -keep-executable
odin test rune/geometry -linker:msvc -out:build/geometry-tests.exe
```

The geometry tests compare exposed unit faces across chunks, check winding,
bounds, sparse/partial chunks, repeatability, and invalid input. The collision
validator also walks a capsule in both directions over independent chunk seams.

For GPU material, fallback color, hot reload, collision coexistence, and cleanup checks:

```powershell
odin run tools/static_mesh_material_validation -collection:rune=rune -linker:msvc -collection:r3d=third_party/r3d-odin -out:build/static_mesh_material_validation.exe -keep-executable -- --runtime
```

Surface extraction rejects invalid dimensions, palettes, and spacing. It is
limited to 1024 voxels per axis and 134,217,728 cells. Installed meshes are
limited to one million vertices and six million indices. Windows and Linux
use the same source; Linux runtime verification must be performed separately.
