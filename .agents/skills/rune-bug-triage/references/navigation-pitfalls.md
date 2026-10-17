# Navigation bake and route-quality pitfalls

Paths are relative to the Rune checkout. Recheck current source before applying
historical observations below.

## Direct surface routes and approximate corridor selection

Relevant sources: `rune/navigation/bake_simplify_3d.odin`,
`rune/navigation/mesh_3d.odin`, `rune/navigation/path_3d.odin`,
`rune/navigation/path_direct_3d.odin`,
`rune/navigation/path_clearance_3d.odin`, and `docs/navigation-3d.md`.

Current queries first trace the direct X/Z line between projected endpoints
through actual shared edges. This avoids unnecessary center-cost corridor
selection when that line follows a permitted connected surface. The trace
preserves each surface crossing and height, filters slope/blocked triangles,
and cannot bridge holes, disconnected triangles, or overlapping floors.
Queries wider than the baked radius also check whole-segment extra clearance.
Trace acceptance checks segment endpoints against their convex triangles in
world space; parameter-space tolerances must not bridge a hole on long queries.

When no direct surface route is accepted, ordinary queries still use
center-to-center A* followed by funnel smoothing of the selected corridor.
Those approximate costs can choose a geometrically longer corridor. The direct
X/Z trace also does not optimize XYZ travel over alternative sloped surfaces.
Keep the documented absence of a globally shortest-path guarantee.

The simplifier merges coplanar cells into rectangles. Extra boundary vertices
preserve matching seams; rectangles with those vertices use center fans that
can contain thin triangles. Valid geometry, connectivity, and a successful
query therefore do not alone establish route quality.

### Historical regression fixture

Before ordinary queries gained the direct trace, a headless Windows AMD64 repro
on 2026-10-17 at `d227400`, with Odin `dev-2026-10-nightly:84bc3fc`, established
the following fixture.

Reproduce with a 20-by-20 floor at y=0 and a 2-by-3-by-2 obstacle box centered
at (0, 1.5, 0), marked as an obstacle. Default bake settings use cell_size=0.5,
agent_radius=0.4, and simplify=true. Query from (-2.87, 0, 2.17) to
(5.13, 0, 2.17), with radius=0.3 and max_projection=0.001:

| Bake/query variant | Observed route length |
| --- | --- |
| Simplified, 18 triangles | 13.473789 |
| Unsimplified, 5520 triangles | 8.032552 |
| Same simplified mesh, query radius=0.45 | 8.000000 |
| Simplified, cell_size=0.25 | 12.752845 |
| Simplified, cell_size=0.125 | 12.409952 |

Both bake variants retain 1380 walkable cells at cell_size=0.5. The direct route
is 8 units and is connected through shared edges. The longer selected corridor
costs 17.903076 by triangle centers, while the direct corridor costs 19.198418:
the approximate graph objective prefers the geometrically longer route.

At that revision, only queries wider than the baked radius tried the direct
connected-surface trace; ordinary queries immediately used centroid A*.
Record both baked and requested radii, and preserve intended agent dimensions
when investigating search differences. A larger radius is not a route-quality
workaround.

Centroids remain inside their triangles, which are supported walkable surface.
A useful crossing can be far from the centroid. A fully walkable triangle's
uniform area centroid is already its vertex average. Portal-midpoint costs also
approximate geometric travel; incoming-to-outgoing portal costs need suitable
arrival state, endpoint costs, and a compatible heuristic. Verify any proposed
change with alternate corridors, ramps, blocked triangles, and separate floors.

The existing navigation tests and bake validator passed at `d227400` despite
this detour. Bake coverage, area, connectivity, and triangle reduction checks do
not measure route quality. Compare actual path length and corridor containment,
including an unobstructed straight-line control, the same geometry with
simplification disabled, and a blocked direct route that requires fallback.

Current regression coverage lives in `rune/navigation/path_direct_3d_test.odin`
and `rune/navigation/path_direct_precision_test.odin`. It requires the fixture's
8-unit route in both directions, with simplified and raw meshes, 0.25-unit finer
cells, and query radii 0.3 and 0.4. It also checks blocked/hole fallback, real
shared edges, separate floors, ramp heights, slope limits, result ownership,
and large-coordinate hole rejection. On 2026-10-17, all 13 navigation tests
passed headlessly on Windows AMD64 and Linux AMD64 under WSL2 with the compiler
version above. Bake validation and 3D navigation/controller validation also
passed; the latter used the example course fixture from `d227400`. These checks
establish CPU path/movement behavior, with no graphical or physical-device
coverage claim.

## Check the actual route before asserting constant heading

Record generated-mesh provenance as well as search-code provenance. Rebaking
can change an agent's valid route around an obstacle even when its endpoints
stay the same. An obstacle's baked inset can force a ramp approach to bend;
turning toward that bend is expected, so a constant-yaw assertion alone does
not establish a motor or pathfinding regression.

`tools/navigation_3d_validation/ramp_facing.odin` keeps turning/arrival checks on
obstructed approaches and uses a clear lane for steady cruise. Before asserting
constant heading, its cruise check requires a complete route with the authored
agent options, unchanged projected endpoints, constant Z, and monotonic X in
the travel direction. Preserve those route preconditions and speed/sample/
arrival checks when updating fixtures; inspect the path rather than weakening
movement thresholds. See `docs/navigation-3d.md` for baking, clearance, and
turning contracts.

With the 34-triangle rebaked example course, the full headless 3D navigation
validator passed on Windows AMD64 and Linux AMD64 under WSL2 on 2026-10-17,
using the compiler version above. Restoring the obstructed cruise lane fails
the straight-route precondition. This covers CPU path/movement behavior.
