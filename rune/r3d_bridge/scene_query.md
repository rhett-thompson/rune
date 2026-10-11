# Rendered scene queries

`scene_raycast(world, origin, translation, ignore=0, bridge=nil, ignored_subtrees=nil)` picks the nearest enabled rendered cube, plane, quad, sphere, or runtime static mesh along a bounded world-space segment. It works without a GPU context and includes render-only geometry. `ignore` excludes one exact entity; `ignored_subtrees` excludes each supplied root and every descendant. Supply all assembly roots when an object contains sibling parts.

The hit includes its entity, world point, distance, and a unit world-space normal oriented toward the ray origin. Normals use the inverse-transpose transform, including nonuniform scale; either side of a triangle can be used for placement.

`scene_projected_bounds(world, root, origin, direction, include_disabled=false)` returns minimum and maximum world-unit projections relative to `origin` over the enabled rendered root and its descendants. Authoring tools can pass `include_disabled=true` to measure hidden source geometry, including disabled descendants and ancestors. It normalizes `direction`, uses transformed primitive corners and CPU static-mesh vertices, and calculates exact ellipsoid support for scaled spheres. The result is unpadded, including zero-thickness planes. Missing roots, invalid vectors, zero directions, and subtrees without supported rendered geometry return `found=false`.

Both queries follow Rune's composed TRS hierarchy. Terrain, shader displacement, transparency, volumes, and unsupported primitives are excluded. Callers own object assembly selection, input, placement policy, and persistence.
