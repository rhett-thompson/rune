# Runtime static geometry

`rune:geometry` provides finite voxel surface extraction. A `Volume` contains
X-contiguous `[]u8` cells, dimensions, spacing, and origin. Zero is air; other
values index a caller-provided RGBA palette. `fill_box` fills half-open bounds.
`surface` emits outward triangles and greedily merges coplanar faces of the
same color index. Solid/solid boundaries are omitted. The caller owns the
returned `Mesh`; release it with `geometry.destroy_mesh`.

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

Run the headless ownership/collision validator (also discovered by
`tools/validate.ps1`) from the Rune root:

```powershell
odin run tools/static_mesh_validation -collection:rune=rune -out:build/static_mesh_validation.exe -keep-executable
odin test rune/geometry -out:build/geometry-tests.exe
```

The geometry tests compare exposed unit faces across chunks, check winding,
bounds, sparse/partial chunks, repeatability, and invalid input. The collision
validator also walks a capsule in both directions over independent chunk seams.

For GPU material, fallback color, hot reload, collision coexistence, and cleanup checks:

```powershell
odin run tools/static_mesh_material_validation -collection:rune=rune -collection:r3d=third_party/r3d-odin -out:build/static_mesh_material_validation.exe -keep-executable -- --runtime
```

Surface extraction rejects invalid dimensions, palettes, and spacing. It is
limited to 1024 voxels per axis and 134,217,728 cells. Installed meshes are
limited to one million vertices and six million indices. Windows and Linux
use the same source; Linux runtime verification must be performed separately.
