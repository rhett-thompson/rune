# Rune

Rune is a small, code-first game engine written in Odin. Projects, scenes, and later prefabs are readable JSON files; gameplay behavior remains Odin code.

## Current slice

The initial scaffold provides:

- a raylib-backed engine loop;
- JSON `project.json` and scene loading;
- an ECS world with registered, JSON-backed custom components;
- dedicated packages for assets, input, rendering, scenes, and future r3d integration;
- a runnable hello-world example.

## Runtime lifecycle

The engine separates simulation from presentation using Unity-like callback
names. Pass an `on_update` procedure for gameplay and component-data changes,
and an `on_draw` procedure for camera/UI drawing and scene rendering:

```odin
engine.run(&game, on_update, on_draw)
```

`Transform`, `SpriteRenderer`, `MeshRenderer`, and `SphereRenderer` are data
components. Their behavior stays in Odin systems, rather than turning scene
JSON into scripts.

`third_party/r3d` is pinned to r3d `v0.10.0` and is reserved for the engine's later 3D renderer. The first example deliberately uses the bundled Odin raylib binding so the 2D foundation stays small.

## Run the example

From the repository root on Windows:

```powershell
odin run examples/hello_world -collection:engine=engine
```

The example loads `project.json` and `scenes/main.scene.json`, then renders a small window using Rune's core loop.

## Custom components

`engine.init` automatically creates the component registry and registers the
built-ins. Scene instantiation discovers component names recursively and
automatically registers missing names as JSON-backed custom components. This
means a scene can declare `Health` or `Mover` without an earlier registration
call. Game code still owns behaviour: automatic registration does not generate
an Odin type or system from JSON.

```odin
entity := ecs.create_entity(&world)
ecs.register_component(engine.component_registry(&game), ecs.Component_Descriptor{
    name = "Health",
    description = "Hit points for damageable entities",
})
ecs.add_component(&world, engine.component_registry(&game), entity, "Health", health_json)
```

`health_json` is a `json.Value`; it can come directly from a scene or prefab JSON
component block. Typed Odin component storage and serializers can be added later
without changing the JSON-facing format.

The typed built-ins are `Transform`, `SpriteRenderer`, `MeshRenderer`, and
`SphereRenderer`. Custom-component systems can read and modify `Transform` by
entity ID:

```odin
transform, ok := ecs.get_transform(&world, entity)
if ok {
    transform.position[0] += speed * dt
    ecs.set_transform(&world, entity, transform)
}
```

## Scene-owned rendering

The scene renderer walks the entity hierarchy. For every entity, it pushes a
matrix, applies its `Transform`, draws its supported render component, draws
its children in that transformed space, then pops the matrix. A normal game
system therefore only changes component data; it does not call `rlgl.PushMatrix`,
`rlgl.PopMatrix`, or draw a `MeshRenderer`/`SphereRenderer` itself.

```odin
render.draw_scene_3d(&world, scene_view)
```

`MeshRenderer` currently draws the `cube` primitive and `SphereRenderer` draws
a sphere. `SpriteRenderer` remains registered as the planned 2D asset-backed
renderer; texture caching and its scene draw path will land with the asset
manager slice.

Validate scene-to-typed-transform loading without starting a game window:

```powershell
odin run tools/component_validation -collection:engine=engine
```

## 3D hello world

The 3D sample loads a JSON scene and shows a rotating cube with a perspective camera:

```powershell
odin run examples/hello_3d -collection:engine=engine
```

## Solar-system hierarchy

This sample shows nested scene entities and transform inheritance: `Sun > Earth > Moon`.

```powershell
odin run examples/solar_system -collection:engine=engine
```

## Custom component updating a Transform

This example lets scene loading auto-register the game-defined `Mover`
component. Its JSON `speed` value is read by an Odin system, which updates the
entity's typed `Transform` every frame.

```powershell
odin run examples/custom_mover -collection:engine=engine
```
