# Entity activation, shapes, and lifetimes

These features work through scene/prefab JSON and Odin APIs. Run the example:

```powershell
odin build examples/shapes_2d -collection:rune=rune -out:build/shapes_2d.exe
./build/shapes_2d.exe
```

On Linux, use `-out:build/shapes_2d` and `./build/shapes_2d`.

## Entity activation

Entities default to enabled. Set `"enabled": false` alongside `id`, `components`,
and `children` in a scene or prefab. Scene instances can override a prefab's
setting with either `true` or `false`; omission inherits the prefab setting.

```json
{
  "id": "effects",
  "enabled": false,
  "children": [
    {
      "id": "flash",
      "components": {
        "Transform": { "position": [120, 80, 0] },
        "ShapeRenderer2D": { "shape": "circle", "radius": 24 },
        "Lifetime": { "seconds": 0.5 }
      }
    }
  ]
}
```

```odin
ecs.set_enabled(world, entity, false)
ecs.is_locally_enabled(world, entity) // This entity's authored/runtime setting.
ecs.is_enabled(world, entity)         // Also checks every ancestor.
```

Disabling a parent suspends its descendants without changing their local
settings. Re-enabling the parent restores only children whose own setting is
true. Reparenting immediately updates inherited activation.

Disabled entities keep their handles, metadata, components, hierarchy, and
runtime state. They are omitted from scene rendering, lights, active camera and
listener selection, built-in simulation, and normal component queries. Native
physics bodies are removed immediately, so raycasts and overlap queries omit
them before the next simulation tick. Re-enabling rebuilds native bodies from
retained component values; backend contact/sleep state is not preserved.

Audio playback pauses on the next `audio.update`, which continues while the game
is paused. Re-enabling resumes the sound voices and music streams that were
playing. Explicitly stopping suspended audio cancels its pending resume. New
play requests on disabled entities return false.

Custom systems should use `ecs.query`, `query2`, `query3`, or
`entities_with_component`; each excludes disabled entities by default. Systems
that directly iterate public storage maps or retain query results must check
`ecs.is_enabled` themselves. System callbacks still run normally.

```odin
for entity in ecs.query2(world, ecs.Transform, PlayerController) {
    // Only effectively enabled entities.
}
all := ecs.query(world, PlayerController, include_disabled = true)
```

`ecs.get`, `ecs.set`, component membership checks, and console inspection still
work on disabled entities. Activation is an entity-level setting; individual
components do not have separate enable flags.

Console commands `enable <entity-id>` and `disable <entity-id>` change the local
setting without saving files. `entities` and `inspect` include both `enabled`
(local) and `enabled_in_hierarchy` (effective). Reload restores the disk settings.

## ShapeRenderer2D

Shapes share the sprite/tilemap/text draw list and active `Camera2D`, with the
same inherited position, scale, rotation, and deterministic `draw_order` sorting.
They require no texture asset.

```json
"ShapeRenderer2D": {
  "shape": "rectangle",
  "size": [100, 60],
  "radius": 30,
  "origin": [0.5, 0.5],
  "color": [60, 140, 230, 255],
  "filled": true,
  "line_width": 2,
  "draw_order": 0
}
```

- `shape`: `rectangle` (default) or `circle`.
- `size`: positive rectangle width/height, default `[32, 32]`.
- `radius`: positive circle radius, default `16`.
- `origin`: pivot relative to the shape's bounding box, default `[0.5, 0.5]`.
- `color`: RGBA bytes, default opaque white.
- `filled`: default `true`; `false` draws an outline.
- `line_width`: positive outline width in world units, default `1`; camera zoom
  scales it, while entity scale only affects the outline's path.
- `draw_order`: integer from -1,000,000 to 1,000,000, default `0`.

Circles use 64 segments and become ellipses under nonuniform scale. Shapes follow
negative scale as well as rotation. Both dimensions and radius must remain
positive even when the selected shape does not use them.

```odin
shape := ecs.default_shape_renderer_2d()
shape.shape = .circle
shape.radius = 24
shape.color = {255, 100, 40, 255}
ecs.add(world, registry, entity, shape)
shape.filled = false
ecs.set(world, entity, shape)
```

## Lifetime

```json
"Lifetime": { "seconds": 2.5 }
```

`seconds` is required, finite, and nonnegative. The scene loop advances lifetimes
once per simulation update, after gameplay, animation, and particle updates.
An expired entity and its descendants are destroyed through `ecs.destroy_entity`,
including their components and native subsystem resources.

The countdown is suspended while the game is paused or the entity is effectively
disabled. Paused console stepping advances it by the simulation timestep. A zero
lifetime expires on the next positive simulation update, not during scene load.

Elapsed time is runtime-only; inspection/serialization reports the configured
duration. Setting or replacing `Lifetime` explicitly restarts its countdown,
even when the duration is unchanged. Removing it cancels expiry. A full scene
reload restarts lifetimes; an in-place value reload preserves elapsed time for
unchanged lifetime settings and resets it when the duration changes.

```odin
ecs.add(world, registry, entity, ecs.Lifetime{seconds = 2})
ecs.set(world, entity, ecs.Lifetime{seconds = 2}) // Restart.
```

Callback-loop users call `ecs.update_lifetimes(world, dt)` once per simulation
update. The scene-owning loop calls it automatically.

## Validation

`tools/component_features_validation` tests loading, prefab overrides, activation
inheritance, reparenting, query filtering, JSON roundtrips and rejection, lifetime
reset/expiry/reload, and 2D/3D physics cleanup. `--runtime` adds GPU pixel checks and
silent native sound/music suspension checks. The tool is included in
`tools/validate.ps1`, including its optional `-Runtime` pass.
