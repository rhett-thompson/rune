# Physics queries and events

Rune delegates collision detection and simulation to Odin's Box2D and Box3D
vendor packages. These APIs translate native shapes into Rune entities and
collect events at the fixed-step boundary.

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

All four native collider components accept `"is_sensor": true` in JSON or
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
3D box and sphere colliders can generate separate contacts. There is no
per-step “stay” event. Each buffer lasts until the next physics update for its
dimension or world shutdown. Reading does not consume it, so multiple systems
can observe the same events.

The engine runs `fixed_update`, both physics backends, then `post_physics`
for each fixed step, in system registration order within each phase. Read in
`post_physics` to see every step, including frames with multiple steps.
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
