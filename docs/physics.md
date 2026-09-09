# Physics queries and events

Rune delegates collision detection and simulation to Odin's Box2D and Box3D
vendor packages. These APIs translate native shapes into Rune entities and
collect events at the fixed-step boundary.

For 3D character movement, see [CharacterController3D](character-controller-3d.md):
a fixed-step query capsule with slopes, stairs, crouching, and moving supports.

## 2D collider authoring

`BoxCollider2D`, `CircleCollider2D`, `CapsuleCollider2D`, `PolygonCollider2D`,
and `SegmentCollider2D` accept an optional
`offset` vector, defaulting to `[0, 0]`. This moves the collision shape relative
to the entity's origin without moving its sprite, child visuals, or Transform.

```json
"BoxCollider2D": { "size": [24, 40], "offset": [0, -20] }
```

```json
"CircleCollider2D": { "radius": 12, "offset": [8, -12] }
```

```json
"CapsuleCollider2D": {
  "radius": 8,
  "height": 32,
  "axis": "vertical",
  "offset": [0, -16],
  "is_sensor": false
}
```

Capsule `height` is the full tip-to-tip length along its axis, including both
round caps. It must be at least twice the positive `radius`. Defaults are radius
`8`, height `32`, and axis `vertical`; use `horizontal` for a sideways capsule.
When height equals diameter, the shape is a circle but queries and events still
identify its component as `CapsuleCollider2D`.

Offsets and dimensions use the entity's own `Transform.scale`: offsets retain
its sign, while dimensions use absolute scale. Circle/capsule radii use the
larger absolute X/Y scale to remain round under nonuniform scaling; capsule cap
centers scale along the selected axis. Consequently, nonuniformly scaled
capsules are conservative round-capped shapes rather than ellipses. Zero-area
shapes are omitted from the native body until scale is restored.

The current 2D physics model fixes body rotation and uses each entity's own
Transform. Transform rotation and parent transforms affect rendering, but do
not rotate or reposition native 2D colliders. Use the capsule's `axis`, polygon
vertices, or segment endpoints to choose physical orientation. Gizmos follow
the same geometry as physics.

An entity may carry one of each collider type. All its colliders share one
native body and can have independent offsets and sensor settings. Attach
`RigidBody2D` for a dynamic or kinematic body; colliders without it are static.
This supports a solid capsule plus an offset box sensor on the same entity.

```odin
capsule := ecs.default_capsule_collider_2d()
capsule.radius = 12
capsule.height = 48
capsule.offset = {0, -24}
ecs.add(world, registry, player, capsule)

capsule.offset[0] = 4
ecs.set(world, player, capsule)
```

Generic `ecs.add/get/set/query` and named capsule accessors are available.
Box/circle colliders also support typed `ecs.add` with offsets. Invalid sizes,
non-finite offsets, invalid capsule axes, or heights below diameter are rejected.
The JSON schema supplies field completion; Rune additionally validates the
relationship between height and radius.

Typed setters, console field edits, and changed scene values rebuild native
shapes before the next raycast/overlap query. Removal, activation, and lifetime
cleanup apply to capsules exactly as they do to other colliders. Rebuilds retain
component values and reset backend contact state, so existing contacts can emit
an end followed by a new begin.

Try the [2D collider playground](../examples/colliders_2d/README.md). It shows
feet-based player origins, a capsule platform, offset box/circle geometry,
sensors, rays, and collider gizmos without external assets.

For platformer movement, [CharacterController2D](character-controller-2d.md)
drives a dynamic body with a vertical capsule, adding slope limits, ground
snapping, acceleration, and jump grace periods.

## Convex polygons and segments

```json
"PolygonCollider2D": {
  "vertices": [[0, 0], [300, -120], [380, -120], [380, 0]],
  "offset": [0, 0],
  "is_sensor": false
}
```

`vertices` is required: supply 3–8 finite points along the perimeter in either
clockwise or counterclockwise order. Do not repeat the first point at the end.
Rune rejects concave, self-intersecting, duplicate, collinear, and too-close
vertices; it does not silently convert a concave outline into its convex hull.
Box2D must retain every vertex when computing the hull. Concave obstacles can
be authored as separate convex entities; automatic decomposition is deferred.

```json
"SegmentCollider2D": {
  "start": [0, 0],
  "end": [260, -52],
  "offset": [0, 0],
  "is_sensor": false
}
```

Both endpoints are required and must be finite and more than 0.005 units apart.
Segments have zero thickness and collide from both sides by default. They work well for
static floors, boundaries, and thin ramps. Segment–segment solid collision is
unsupported by Box2D; use a box or polygon when a body needs volume. Independent
segments do not provide chain adjacency or ghost vertices, so joined edges can
produce seams. Horizontal segments and boxes support `"one_way": true` for
collision on their top face only. One-way colliders cannot be sensors, and
one-way segments require equal endpoint Y coordinates. See
[one-way collision and drop-through](character-controller-2d.md#one-way-platforms-and-dropping).

For both types, each local point becomes
`Transform.position.xy + (point + offset) * Transform.scale.xy`.
Negative scale reflects the geometry; nonuniform scale changes its shape.
Geometry collapsed below Box2D's tolerance is omitted until a usable scale is
restored. Transform rotation and hierarchy follow the limitations above.

Both types support sensors, collision layers, raycasts, overlaps, contact events,
activation, prefabs, scene reload, and runtime field edits. Query hits and events
report `PolygonCollider2D` or `SegmentCollider2D` as the component name. Polygon
sensors cover their interior; segment sensors detect shapes crossing their edge.

```odin
vertices := [3][2]f32{{0, 0}, {100, -40}, {100, 0}}
ecs.add(world, registry, ramp, ecs.PolygonCollider2D{vertices = vertices[:]})
ecs.add(world, registry, edge, ecs.SegmentCollider2D{start = {0, 0}, end = {100, 0}})

// add/set copy polygon vertices. Getters return a borrowed read-only slice;
// copy its points into your own buffer before editing, then call ecs.set.
vertices[1][1] = -60
ecs.set(world, ramp, ecs.PolygonCollider2D{vertices = vertices[:]})
```

Runtime edits use the same validation and rebuild the native body:

```text
set ramp PolygonCollider2D.vertices.1.1 -160
set bridge SegmentCollider2D.end [260,-80]
```

Invalid edits preserve the previous component. Try the
[ramps example](../examples/ramps_2d/README.md) for a capsule walking up a polygon
onto a segment bridge, a polygon sensor, and a downward raycast.

## Queries

```odin
filter := ecs.Default_Physics_Query_Filter
filter.ignore = player
filter.include_sensors = false

// A segment from origin to origin + translation; no normalization required.
hit, found := ecs.physics_2d_raycast(world, {100, 200}, {300, 0}, filter)
if found {
    // hit.entity, hit.component, hit.point, hit.normal, hit.fraction
}

nearby := ecs.physics_2d_overlap_circle(world, {100, 200}, 80)
inside := ecs.physics_3d_overlap_box(world, {0, 1, 0}, {2, 1, 2})
```

| API | Shape/input |
| --- | --- |
| `physics_2d_raycast` | Origin and translation as `[2]f32`; closest hit and bool |
| `physics_3d_raycast` | Origin and translation as `[3]f32`; closest hit and bool |
| `physics_2d_overlap_box` | Center and positive half-size as `[2]f32` |
| `physics_2d_overlap_circle` | Center as `[2]f32`, positive radius |
| `physics_3d_overlap_box` | Center and positive half-size as `[3]f32` |
| `physics_3d_overlap_sphere` | Center as `[3]f32`, positive radius |

Overlap boxes are axis-aligned query volumes, tested against the native shape
geometry, including rotated 3D colliders. Results contain sorted, unique entity
IDs; multiple colliders on an entity do not duplicate that entity.

All queries accept an optional `Physics_Query_Filter`. Start with
`Default_Physics_Query_Filter`, which includes every layer and sensors.
`layers` is a bitmask intersected with native collision filters; zero matches
nothing. `ignore` excludes one entity. Rune's existing collision rule remains
that entities must share at least one layer to collide.

Queries create new or rebuilt native bodies as needed, including before the
first physics step, without advancing simulation. Typed transform, collider,
and layer edits are reflected in the next query. They only see colliders
represented in the selected native world; tilemap-only movement and the simple
`CharacterController` volume are separate systems.

Overlap results use `context.temp_allocator` by default and expire when that
allocator resets (normally the end of the game frame). To keep them longer,
pass `allocator = context.allocator` and `delete(results)` when finished.
Raycast results are values. Zero-length rays, non-finite inputs, and non-positive
overlap extents return no hits. Raycasts retain the backend's behavior for rays
starting inside a shape; use an overlap query to detect containing shapes.

## Sensors and events

All native collider components accept `"is_sensor": true` in JSON or
`is_sensor = true` in Odin. It defaults to false.

```json
{
  "Transform": { "position": [300, 200, 0] },
  "BoxCollider2D": { "size": [24, 24], "is_sensor": true }
}
```

Sensors report overlaps without applying collision response. Native backend
rules determine which body types generate events; the example uses a static
sensor and a dynamic visitor. The simple 3D character controller ignores sensor
colliders for blocking, but its movement volume does not itself generate native
sensor events.

Register a system's `post_physics` callback to read events:

```odin
after_physics :: proc(game: ^rune.Engine, world: ^ecs.World) {
    for event in ecs.physics_2d_events(world) {
        if event.is_sensor && event.kind == .Begin &&
           event.b.entity == player && ecs.is_alive(world, event.a.entity) {
            ecs.destroy_entity(world, event.a.entity)
        }
    }
}
```

`physics_2d_events` and `physics_3d_events` return borrowed slices of
`Physics_Event`:

- `kind`: `.Begin` or `.End`.
- `a` and `b`: `Physics_Shape` values containing `entity` and collider
  `component` name.
- `is_sensor`: for sensor events, `a` is the sensor and `b` the visitor.
  Solid-contact ordering follows the backend.

Events describe shape pairs, not aggregate entity pairs. An entity with both
box and circle/capsule colliders, or 3D box and sphere colliders, can generate
separate contacts. There is no
per-step “stay” event. Each buffer lasts until the next physics update for its
dimension or world shutdown. Reading does not consume it, so multiple systems
can observe the same events.

The engine runs `fixed_update`, both physics backends, then `post_physics`
for each fixed step, in system registration order within each phase. Read in
`post_physics` to see every step, including frames with multiple steps. Use
`game.fixed_delta_time` for timing in these callbacks; `game.delta_time` holds
the simulation frame delta, which may span several fixed steps.
Standalone callers can call `physics_2d_update` / `physics_3d_update` and
read immediately afterward; one call accumulates events from all its substeps.

Gameplay can destroy entities or edit colliders while reading the buffer.
Rune queues removal ends for the next physics update, without modifying the
published slice. Rebuilding a touching collider can produce an old-pair end
followed by a new-pair begin. End events may reference removed entities; check
`ecs.is_alive` before accessing their components. Full scene replacement and
physics shutdown clear events and pairs.

## Direct backend access

`world.box2d_world` and `world.box3d_world` expose native world IDs.
`physics_2d_native_body` / `physics_3d_native_body` return a native body ID
and validity flag. `physics_2d_entity_from_shape` /
`physics_3d_entity_from_shape` map a valid Rune-owned shape ID to
`Physics_Shape` and a bool.

These allow backend-specific queries, forces, joints, and other advanced
operations. Keep Rune-owned body/shape creation, removal, and collider edits
through Rune APIs so its caches and buffered events stay consistent. Native
handles can change when colliders, scale, layers, or scenes change. Externally
created shapes have no automatic Rune entity mapping.

## Example and validation

Run from the repository root:

```powershell
odin build examples/physics_queries_2d -collection:rune=rune -out:build/physics_queries_2d.exe
./build/physics_queries_2d.exe
odin build tools/physics_query_validation -collection:rune=rune -out:build/physics_query_validation.exe
./build/physics_query_validation.exe
```

The example uses A/D movement, three sensor pickups, a right-facing ray, and a
proximity circle. It requires no external media. Console pause/input/step,
inspection, captures, and reload work as in the other scene examples.

`tools/collider_2d_validation` covers typed and JSON authoring, signed/scaled
offsets, compound bodies, capsule geometry, sensors, grounding, native cleanup,
and value reload. Its optional `--runtime` mode checks actual gizmo pixels. Both
passes are included in `tools/validate.ps1` (`-Runtime` enables pixel checks).

While a `CharacterController2D` crouches, its authored capsule remains unchanged.
Use `get_effective_capsule_collider_2d` to read live dimensions and offset;
physics queries and gizmos already use the effective shape. See
[crouching and safe standing](character-controller-2d.md#crouching-and-safe-standing).
