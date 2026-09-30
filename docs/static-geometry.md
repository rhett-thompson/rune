# Runtime static geometry

`rune:geometry` provides finite voxel surface extraction. A `Volume` contains
X-contiguous `[]u8` cells, dimensions, spacing, and origin. Zero is air; other
values index a caller-provided RGBA palette. `fill_box` fills half-open bounds.
`surface` emits outward triangles and greedily merges coplanar faces of the
same color index. Solid/solid boundaries are omitted. The caller owns the
returned `Mesh`; release it with `geometry.destroy_mesh`.

`ecs.set_static_mesh(world, entity, mesh)` copies validated vertex/index data
and installs static triangle collision. An entity needs a `Transform` with
positive scale and cannot also own Terrain, a native 3D collider/body, or a
character controller. Positions are welded for Box3D edge identification;
render normals/colors remain split. Physics rays and overlaps report component
`StaticMesh`, and CharacterController3D collides with the surface. Effective
activation, positive transform scaling, rotation, parent transforms, and layer
filters follow the terrain transform rules. Queries synchronize these edits
without advancing simulation. Invalid mesh replacements retain the old data.

The R3D bridge uploads meshes automatically when drawing a World. It owns GPU
copies keyed by entity and revision; deletion, replacement, World changes,
and bridge shutdown release them. World/entity destruction releases CPU and
Box3D mesh resources. `ecs.remove_static_mesh` releases just the runtime mesh.

These meshes are runtime data, not serialized scene components. Recreate them
from game-owned data after scene reload. This API does not generate gameplay
meaning, navigation graphs, or scene JSON.

Run the headless ownership/collision validator (also discovered by
`tools/validate.ps1`) from the Rune root:

```powershell
odin run tools/static_mesh_validation -collection:rune=rune -out:build/static_mesh_validation.exe -keep-executable
```

Surface extraction rejects invalid dimensions, palettes, and spacing. It is
limited to 1024 voxels per axis and 134,217,728 cells. Installed meshes are
limited to one million vertices and six million indices. Windows and Linux
use the same source; Linux runtime verification must be performed separately.
