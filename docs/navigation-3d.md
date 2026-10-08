# 3D navigation

Rune provides automatic static-geometry baking, triangle navmeshes, A* corridor queries, click projection, and
fixed-step agents for grounded 3D movement. Paths follow ramps in XYZ, and
overlapping floors remain separate unless their triangles are connected.

The [Navigation 3D example](../examples/navigation_3d/README.md) routes a capsule
around an obstacle and up a ramp. Press B to block the connecting passage.

## Scene setup

```json
{
  "entities": [
    {
      "id": "navigation",
      "components": {
        "NavMesh3D": { "asset": "assets/level.navmesh.json" }
      }
    },
    {
      "id": "guard",
      "components": {
        "Transform": { "position": [1, 0, 1] },
        "NavAgent3D": {
          "mesh": { "id": "navigation" },
          "speed": 3,
          "radius": 0.3,
          "height": 1.8
        }
      }
    }
  ]
}
```

`NavMesh3D` references a project-relative asset. Its vertices are world-space
coordinates; it does not require a Transform, and parenting/transforming its entity
does not move the geometry. Disable its entity to make its surface unavailable.

`NavAgent3D` requires an unparented, unit-scale Transform. Its position is at the
feet. By default it directly moves the Transform along the surface. This mode
does not perform physical collision or apply gravity. A RigidBody3D cannot share
the entity, since it would also own movement.

To use native capsule movement, add `CharacterController3D` and set
`NavAgent3D.drive_controller` to true. Navigation supplies X/Z movement requests;
the motor handles gravity, ramps, steps, and solid collision. Configure the
navigation radius/height to cover the motor's standing capsule, and use a
navigation slope limit no greater than the motor's. Actual speed is capped by
the motor's `move_speed`. The physical level must match the navmesh.
Controller speed is measured along the ground surface; its horizontal component
is smaller on a slope. Grounded acceleration and braking preserve that surface
speed across fixed steps.

The bake must provide at least the agent's radius and height clearance, and its
walkable slope limit must include the slopes the agent needs. Raising an agent's
`max_slope` does not restore surfaces already removed by the bake.

## Targets and state

```odin
agent, found := ecs.find_entity_by_id(world, "guard")
if found {
    ecs.set_navigation_target_3d(world, agent, {12, 2, 6})
}

state, found := ecs.get_navigation_state_3d(world, agent)
if found && state.status == .Arrived {
    // Choose the next patrol point in game code.
}

ecs.stop_navigation_3d(world, agent)
```

Setting a target queues path calculation for the next navigation fixed step.
Repeatedly setting the identical target preserves the existing path. `stop` clears
the target and the controller's movement request; a moving motor brakes normally.

State exposes `status`, `path_status`, `has_target`, the requested `target`,
`desired_velocity`, `actual_velocity`, `remaining_distance`, `path`, and
`next_point`. `desired_velocity` is the current navigation movement request;
`actual_velocity` reports achieved displacement per second: the previous fixed
step for controller agents and the current step for direct Transform agents.
`remaining_distance` is the distance along the current route to its projected
destination, measured in X/Z for controller agents and XYZ for direct Transform
agents, before subtracting `stopping_distance`. Paths are borrowed until the next
navigation update, target change, component removal, or world destruction.
Copy them if they must outlive that boundary. Do not modify their storage.

| Agent status | Meaning |
| --- | --- |
| `Idle` | No target. |
| `Pending` | Waiting for its first path calculation. |
| `Moving` | Following a complete corridor. |
| `Arrived` | Within the final-goal tolerance and moving at no more than 0.05 units/s. See turning and stopping below for mode-specific distance checks. |
| `No_Path` | Query failed; inspect `path_status`. Retries continue at the configured interval. |
| `Unavailable` | Mesh/reference or required agent setup is unavailable. |
| `Disabled` | Agent is disabled; its target is retained for reactivation. |

The engine syncs navigation assets before startup, reload, and save-restore
callbacks and before each frame's simulation. Navigation runs after game
`fixed_update` systems and before Box2D/Box3D on each fixed step. Do not write
competing movement requests from another system. Pausing stops agents while
asset polling continues. Callback-based loops should call
`ecs.sync_navigation_3d(world, asset_manager)` after asset refresh, then
`ecs.update_navigation_3d(world, fixed_dt)` before physics.

## Agent settings

| Field | Default | Meaning |
| --- | --- | --- |
| `mesh` | Required | Stable entity reference to a NavMesh3D. |
| `speed` | 3 | World units per second; zero stops advancement. |
| `acceleration` | 0 | Direct Transform speed increase in units/s²; zero changes speed instantly. Controller mode uses the motor's acceleration. |
| `braking` | 0 | Direct Transform speed decrease in units/s²; zero changes speed instantly. Controller mode uses the motor's braking. |
| `angular_speed` | 360 | Maximum yaw change in degrees/s when `update_rotation` is true; zero holds facing. |
| `update_rotation` | false | Face the horizontal travel direction using local +Z forward, preserving pitch and roll. |
| `auto_braking` | false | Predictively slow down before the destination using remaining route distance and braking. |
| `corner_slowdown` | false | Predictively slow down before real bends in the route. |
| `radius` | 0.3 | Required authored clearance radius. |
| `height` | 1.8 | Required authored headroom. |
| `max_slope` | 45 | Maximum slope in degrees, from 0 to below 89. |
| `max_projection` | 1 | Maximum XYZ distance for snapping each query endpoint to the mesh. |
| `arrival_distance` | 0.12 | Positive final-goal tolerance, added to `stopping_distance` for arrival. |
| `waypoint_distance` | 0.12 | Nonnegative intermediate controller waypoint tolerance, independent of arrival; zero requires exact waypoints. |
| `stopping_distance` | 0 | Stand-off distance from the projected destination in world units. |
| `repath_interval` | 0.5 | Positive interval between path recalculations. |
| `drive_controller` | false | Drive CharacterController3D instead of writing Transform directly. |

Config changes and mesh revisions force a fresh route on the next navigation
step. Directly moving a Transform also invalidates a Transform agent's old route;
controller agents allow ordinary motor movement before treating a large displacement
as a teleport. If an endpoint is within `max_projection`, the reported arrival
position is its projected surface point, not necessarily the originally requested
coordinate. Set a smaller distance when destinations must already lie on the mesh.

## Turning and stopping

Enable `update_rotation` to turn the agent's facing gradually toward its travel
direction. `angular_speed` limits yaw rotation without making the route curve
outside its corridor. Movement can therefore change direction faster than facing;
the setting controls orientation, not a vehicle's turning radius.
Controller agents face their requested steering direction, so ground snap and
contact corrections do not swing their facing. Direct Transform agents face
their achieved travel direction. Facing holds when the agent stops.

Enable `auto_braking` to start slowing before the destination, using the active
mode's deceleration and remaining route distance. `stopping_distance` allows an
agent to stop short of the projected destination; `arrival_distance` is the
additional tolerance for settling. Direct Transform agents check XYZ distance
against `stopping_distance + arrival_distance`. Controller agents check X/Z
distance against that tolerance and allow a vertical offset of at most the
greater of that tolerance and 0.25 units, accounting for physical ramp contact.
Arrival also waits for speed to fall to at most 0.05 units/s, measured horizontally
for controller agents. While an agent is inside that arrival region but still
braking, its status remains `Moving`. `waypoint_distance` only controls
when a controller agent advances past intermediate points, so increasing arrival
tolerance does not cause it to skip more of an obstacle corner.

Enable `corner_slowdown` to reduce speed before sharp horizontal turns. Collinear
triangle crossings keep full speed, including crossings retained to follow the
surface of a ramp. Replanning preserves the agent's current speed so ordinary
route refreshes do not restart acceleration.
Controller steering aims at the next actual bend along a straight horizontal
section, while retaining the surface crossings for route progress. A fresh
route's projected start anchors the query without becoming a steering goal.

For direct Transform movement, set positive `acceleration` and `braking` values
to ease speed changes. Zero retains instant speed changes; predictive slowdown
has no braking distance to anticipate in that mode. For controller movement,
configure `CharacterController3D.acceleration` and `.braking` instead. Navigation
uses the motor's braking limit when reducing a movement request to a lower,
nonzero speed if `auto_braking` or `corner_slowdown` is enabled, as well as when
stopping. Agents with both options disabled retain the motor's existing response
to analog movement requests. Existing agents keep constant-speed Transform
movement and their existing facing unless these options are enabled.

For example, the Navigation 3D demo enables facing, destination braking, and
corner slowdown with `angular_speed: 360`, `waypoint_distance: 0.08`, and a motor
configured with `move_speed: 3`, `acceleration: 8`, and `braking: 6`.

## Debug visualization

Inspect a loaded mesh with the engine console command `navmesh on`, or
`navmesh on navigation` to select the `NavMesh3D` scene entity named `navigation`.
The overlay draws translucent cyan walkable surfaces, triangle edges, and red
blocked triangles. `navmesh off` hides it; `navmesh` reports its state. This display
is independent of F3 and included in console captures:

```powershell
.\tools\console.bat --directory build/console/navigation --command 'navmesh on' --json
.\tools\console.bat --directory build/console/navigation --command 'capture build/captures/navmesh.png' --json
```

Scene loops draw it through the active `Camera3D`. Games with custom camera
rendering, including the Navigation 3D demo, can call
`gizmos.draw_navmeshes_3d(world, game.gizmos.navmesh_entity)` inside their 3D camera
mode when `game.gizmos.navmeshes` is true. The helper borrows current meshes and
does not require a transform on the navigation entity.

## Baking a navmesh from a scene

Run the CPU-only baker from the repository root:

```powershell
odin run tools/navmesh_baker -linker:msvc -collection:rune=rune -- examples/navigation_3d/course.navbake.json
odin run tools/navmesh_baker -linker:msvc -collection:rune=rune -- examples/terrain_3d/terrain.navbake.json
```

A `*.navbake.json` file selects the scene, output asset and agent settings:

```json
{
  "project_root": ".",
  "scene": "scenes/main.scene.json",
  "output": "level.navmesh.json",
  "settings": {
    "cell_size": 0.5,
    "agent_radius": 0.4,
    "agent_height": 2,
    "max_slope": 45,
    "simplify": true
  }
}
```

`project_root` is relative to the bake config's directory. Scene, output and
terrain asset paths are relative to that project root. The output directory must
exist. The tool reads named layers from `project.json` when present. Point `NavMesh3D.asset` at the resulting file. Failed bakes leave the
previous asset untouched; successful writes atomically replace it, and the engine's
normal navmesh hot reload picks it up. Re-run the command after scene or heightmap
edits. Baking does not run automatically in the frame loop.

The Navigation 3D demo calls the baker itself at startup and after scene reloads.
Press **N** or run `rebake` in its console to bake live scene edits or changed
settings without leaving the example. Manual rebakes preserve active destinations
and ramp closure state, and retain the previous mesh if a bake fails.

The scene collector includes enabled static `BoxCollider` geometry and collision-enabled
`Terrain` components, including prefabs. Static spheres become conservative box
blockers and never walkable roofs. Sensors, dynamic/kinematic bodies and agents
are excluded. Box and sphere placement follows their actual Box3D Transform;
terrain includes its accumulated parent translation, rotation and positive scale.
Visual-only model renderers are not collision sources. Export model triangles or
append procedural geometry through the API below when a level uses those sources.

The baker clips source triangles into an X/Z grid and builds separate vertical
surface layers in each cell. It rejects steep slopes, partial support, low headroom
and surfaces buried inside closed solids. It then removes cells near walls, holes,
ledges and rejected areas for the agent radius, and connects the surviving cells.
By default, `simplify: true` merges connected coplanar cells into rectangles before
triangulation. Shared boundaries retain neighboring rectangle and terrain vertices,
so holes, ramp seams and stacked floors keep their original connectivity. Cells
with nonplanar corner/center samples retain their four triangles. Plane matching
uses a fixed seed and a 0.0001-unit vertical tolerance, rather than accumulating
error across cells. This is a conservative planar merge, not arbitrary terrain
decimation or contour smoothing. It does not invent step, jump or ladder links.

Set `"simplify": false` to skip the merge stage and retain the original
four triangles per surviving cell. Both modes use identical slope, headroom and
radius filtering. Simplification reduces the navigation graph and asset size;
the demo course drops from 6,520 to 55 triangles at the same 0.25-unit resolution.
Meshes still use the same triangle asset format and runtime APIs.

`cell_size` controls accuracy and cost. Smaller cells preserve narrower passages
and more terrain detail. Planar regions simplify even at fine resolution; rough
terrain still generates more triangles with smaller cells. Radius clearance rounds up to
whole cells and uses square rings, so corners and narrow passages are deliberately
conservative. The default is 0.5 units; the terrain example uses 3 units to keep a
256-unit landscape within the output limit. Terrain samples come from the same
heightmap triangles as rendering/collision, across all chunk boundaries. Coarse or
unaligned grids approximate that surface between samples; use smaller cells for
rough terrain and let `CharacterController3D` follow the actual collision surface.
Near a slope threshold or tight ceiling, conservative filtering can disconnect a
route that a human player could traverse.

Bakes allow at most 2,000,000 input triangles, 6,000,000 input vertices, 1,048,576
grid cells, 4,000,000 raster patches, 1,048,576 intermediate walkable cell layers,
and 65,536 final output triangles. Simplification runs before the final mesh limits
are checked. A cell accepts at
most 4,096 patches; unusually complex overlapping coverage fails closed. Radius
must be at most 32 cells. Increase cell size or split the geometry when a limit is
reached. This is an offline whole-mesh baker, without streaming tiles or incremental
obstacle carving.

## Baking from code

```odin
mesh, stats, error := ecs.bake_navigation_world_3d(world, project_root)
if error == "" {
    defer navigation.destroy_mesh_3d(&mesh)
    error = navigation.write_mesh_3d("assets/level.navmesh.json", &mesh)
}
```

The world API works with a game's registered custom components. For standalone
geometry, create `navigation.Bake_Geometry_3D`, append inputs with
`append_bake_triangles_3d`, `append_bake_box_3d` or `append_bake_terrain_3d`, then
call `bake_mesh_3d`. Each helper accepts position, Euler rotation and positive scale.
`append_bake_terrain_3d` accepts CPU `terrain.Data`, so PNG and R16 heightmaps use
the same path. `collect_navigation_geometry_3d` also exposes the scene snapshot
when additional model triangles need appending before baking.

For custom settings in Odin, start from `navigation.Default_Bake_Settings_3D`
(which enables simplification), then change the desired fields. For example,
`settings.simplify = false` selects the original per-cell output. Named Odin struct
literals use zero values for omitted fields, so a literal omitting `simplify`
disables it. Bake JSON retains the defaults when fields are omitted.

Triangle winding matters for baking: upward-facing triangles may be floors;
downward and steep faces obstruct clearance. Use `solid=true` for closed,
consistently outward-wound model geometry, so terrain buried inside it is removed.
Boxes are automatically closed solids. Keep open floors and heightmap surfaces
at the default `solid=false`. `obstacle=true` prevents a source's faces from
becoming walkable. The baker does not repair malformed or non-watertight solids.
Append helpers copy their inputs; release accumulated geometry with
`destroy_bake_geometry_3d`, including collector error paths. Successful baked
meshes are owned and must be released with `destroy_mesh_3d`.

## Authoring a navmesh directly

```json
{
  "version": 1,
  "agent_radius": 0.4,
  "agent_height": 2,
  "vertices": [[0, 0, 0], [4, 0, 0], [4, 0, 4], [0, 0, 4]],
  "triangles": [[0, 1, 2], [0, 2, 3]]
}
```

You can also provide **authored walkable center surfaces** directly. Inset the surface from walls, holes, and ledges
by the advertised `agent_radius`, and check that `agent_height` of headroom exists
throughout it. These fields declare clearance already accounted for by the author
or exporter; loading an already-authored navmesh does not run the baker. Queries
reject agents larger than that clearance. The example includes
`generate_mesh.bat` / `generate_mesh.sh` as a small original geometry-authoring example.

Indices are zero-based. Adjacent triangles must share the same two vertex indices
at their edge; coincident coordinates with different indices are disconnected.
Either winding is accepted. The loader rejects missing/unknown fields, invalid
indices, nonfinite vertices, degenerate/vertical faces, duplicate faces, same-side
shared faces, and edges belonging to more than two triangles. Nonadjacent faces
must not overlap at the same height; spatial self-intersection testing is not
performed. Limits are 131072 vertices and 65536 triangles, with coordinates within
one million world units. The JSON schema provides authoring completion.

Walkable slopes are filtered per query. A* searches the shared-edge triangle graph
using center-distance costs and a binary heap. A funnel straightens the selected
corridor in X/Z, eliminating detours through triangle-edge midpoints. The path
retains each shared-edge crossing at its surface height, so each segment remains
in its corridor triangle, including across ramp seams. `points[i]` to
`points[i+1]` follows `triangles[i]`; crossings on a flat straight leg are collinear.
This does not guarantee the globally shortest route across all possible corridors.
There are no off-mesh jump, ladder, elevator, or teleport links in this version.

## Direct queries and mouse picking

```odin
mesh, ready := ecs.navigation_mesh_3d(world, mesh_entity)
if ready {
    path := navigation.find_path_3d(&mesh, start, goal)
    defer navigation.destroy_path_3d(&path)
    if path.status == .Complete {
        // path.points and path.triangles describe the corridor.
    }
}
```

`find_path_3d` accepts `Path_Options_3D` and an optional allocator. Returned arrays
are owned by the caller. Failed queries have no path and distinguish invalid input,
start/goal off mesh, insufficient clearance, and unreachable destinations. No partial
path is reported as complete.

`navigation.project_point_3d(mesh, point, max_distance, max_slope)` returns the
nearest permitted surface point, triangle index, and success. Distance is measured
in XYZ, so an upper-floor point does not silently become a lower-floor destination.
`navigation.raycast_mesh_3d(mesh, origin, translation, max_slope)` returns the nearest
permitted triangle hit. Translation is the complete ray segment, not a unit direction.
The demo uses a screen-to-world ray for click destinations. Blocked triangles are
excluded from projection, picking, and path searches.

Mesh values returned by `ecs.navigation_mesh_3d` and `assets.navmesh_data` are borrowed
read-only. ECS mesh values remain valid until their next sync/removal or world
destruction; asset values expire on successful reload or manager shutdown.

## Doors, reloads, and persistence

```odin
ecs.set_navigation_triangle_blocked_3d(world, mesh_entity, triangle_index, true)
```

Blocking a triangle increments that surface's revision and invalidates agent routes
on the next fixed step. Call with false to reopen it. Each NavMesh3D entity owns its
blocked flags, even when two entities use the same asset. Whole-mesh disabling also
stops its agents. Physical obstacles do not automatically carve the mesh: game code
must keep logical door blocking and physical door collision in agreement. Blocking
an agent's current triangle can leave it with no route until the area reopens or
game code moves it to a permitted surface.

`hot_reload.navmeshes` defaults to true and follows the project's hot-reload polling.
Invalid asset replacements keep the last working mesh and report one diagnostic;
successful reloads rebuild the world copies and force new paths. Runtime blocked
flags reset when the mesh is rebuilt, so reapply door state after mesh changes.
For callback loops use `assets.refresh_navmeshes` at the polling interval.

Scene component-value reload retains active destinations. Entity/component removal
frees paths and mesh storage; full world replacement starts with no destinations.
Only component settings serialize automatically. With checkpoint saves, reissue
targets and blocked flags from `on_save_restored`, or use game-owned saved state.

This version has no crowd avoidance,
streaming tiles, or dynamic obstacle carving. Motor collision remains authoritative;
an obstacle missing from the authored mesh can physically stop an agent even when
its planned route is complete.

## Validation

```powershell
odin run tools/navigation_3d_validation -linker:msvc -collection:rune=rune -out:build/navigation_3d_validation.exe
odin run tools/navigation_3d_validation -linker:msvc -collection:rune=rune -out:build/navigation_3d_validation.exe -- --runtime
odin run tools/navigation_bake_validation -linker:msvc -collection:rune=rune -out:build/navigation_bake_validation.exe
```

Use an extensionless output on Linux. Headless checks cover geometry/topology,
corridor containment, ramp traversal, overlapping floors, clearance and slope
limits, unreachable/blocked paths, native and Transform movement, turning,
predictive stopping, corner slowdown, speed-preserving replanning, teleportation,
activation, removal, value reload, independent blocked flags, asset recovery, and
project validation. Hidden-window checks exercise startup asset loading, pause,
and the real fixed-step loop. Bake checks cover terrain sampling/transforms,
radius erosion, obstacle volumes, thin walls, low ceilings, deterministic output,
serialization and failure handling. All validators are integrated into `.\tools\validate.bat`.
