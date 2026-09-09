# Prefabs

Prefabs describe reusable entity trees. They can include other prefabs, inherit
from a base prefab, and customize root or child components. Gameplay systems and
custom component registration remain Odin code owned by the consuming game.

## A controller with a reusable camera

For example, `prefabs/camera.prefab.json`:

```json
{
  "name": "Controller Camera",
  "components": {
    "Transform": { "position": [0, 1.6, 0] },
    "Camera3D": { "fovy": 70, "active": true }
  }
}
```

Then `prefabs/player.prefab.json`:

```json
{
  "name": "Player",
  "components": {
    "Transform": {},
    "CharacterController3D": { "move_speed": 6, "jump_speed": 8 }
  },
  "children": [
    { "id": "camera", "prefab": "camera.prefab.json" }
  ]
}
```

A scene can configure that player without copying the camera or movement defaults:

```json
{
  "name": "Controller Example",
  "entities": [
    {
      "id": "player",
      "prefab": "../prefabs/player.prefab.json",
      "component_overrides": {
        "Transform": { "position": [0, 0, 10] },
        "CharacterController3D": { "move_speed": 7 }
      },
      "child_overrides": {
        "camera": {
          "component_overrides": { "Camera3D": { "fovy": 85 } }
        }
      }
    }
  ]
}
```

This supplies data and hierarchy; the game still registers input/movement/look
systems. Custom components such as the first-person example's
`FirstPersonController` can live in these same component blocks after registration.
The `CharacterController3D` motor must remain on the unparented prefab root with
unit scale. A child camera supplies ownership and activation hierarchy; current
`Camera3D` position and target are world-space values, so the look system must
still update them. Prefab composition does not change camera or physics transform
semantics. See [the controller guide](character-controller-3d.md).

## Composition and overrides

- Every `prefab` path is relative to the JSON file containing that reference.
  A scene can reference a shared folder outside its project. A prefab's children
  can reference other prefabs, and a prefab root can reference a base prefab.
- `components` retains the original whole-component replacement behavior. Fields
  omitted from a replaced block use component defaults, not inherited values.
- `component_overrides` recursively merges object fields into an existing
  component. Arrays and scalar values replace the previous value completely.
  `null` is an ordinary JSON value, not a deletion operation; the final component
  must accept it. Use `components` to introduce a component that does not exist.
- `remove_components` is an array of component names to remove. Removing or
  overriding a missing component is an error, helping catch spelling mistakes.
- `child_overrides` maps local ID paths, such as `camera/accessory`, to patches.
  Patches support `enabled`, `name`, `tag`, `layers`, `components`,
  `component_overrides`, `remove_components`, and further `child_overrides`.
  Missing targets and unsupported patch fields are errors. IDs and prefab
  references cannot be changed by a child patch. Disable an unwanted child with
  `"enabled": false`; child deletion/reparenting is not an override operation.
- `children` adds entities; it does not match or replace inherited children.
  Child IDs must be unique among siblings. Children authored in prefab files use
  local IDs; additional children authored in the scene retain scene-global IDs.

At each inheritance layer, Rune resolves the base, applies metadata and whole
component blocks, merges field overrides, removes components, appends children,
then applies child overrides. Parent paths are patched before descendant paths
in lexical order, so overlapping child patches have deterministic results.
Outer instances apply after the referenced prefab's own overrides.

A variant can contain only a name, base reference, and changes:

```json
{
  "name": "Fast Player",
  "prefab": "player.prefab.json",
  "component_overrides": { "CharacterController3D": { "move_speed": 9 } }
}
```

Reference cycles, unreadable prefabs, and nesting beyond 64 levels fail with a
diagnostic rather than recursing indefinitely. Project validation and scene loading
validate the expanded component values using the same resolver.

## Identity, layers, and references

Prefab child `id` values are local names without `/`. Under a scene instance named
`player`, child `camera` gets scene ID `player/camera`; its child `accessory` gets
`player/camera/accessory`. A second instance gets its own independent IDs and data.
Every ancestor of an identified prefab child, including the scene instance, must
have an ID. Existing anonymous prefab children remain supported but cannot be
targeted by ID-based overrides. Display names do not participate in lookup.

```odin
player, player_ok := ecs.find_entity_by_id(world, "player")
camera, camera_ok := ecs.find_prefab_child(world, player, "camera")
accessory, accessory_ok := ecs.find_prefab_child(world, player, "camera/accessory")
```

`find_prefab_child` checks that the result actually belongs to the given instance.
The qualified IDs also work with `ecs.find_entity_by_id`, `ecs.entity_ref`, and
console commands such as `inspect player/camera`.
Entity-reference strings inside arbitrary component data are not automatically
rewritten. Code can store a local child path and resolve it against its instance,
or use an explicitly qualified scene ID for an `Entity_Ref`.

Children may author their own `tag` and `layers`. Omitted child layers inherit
from their parent within the prefab tree; explicitly empty layers select Default.
Scene instances inherit prefab metadata unless they explicitly override it; their
ID always comes from the scene. Project layer names must be declared by the
consuming project. Disabling a parent suspends its entire hierarchy as usual.

Existing `components` overrides, scene-authored child IDs, and project-relative
assets keep their behavior. Adding IDs to prefab-authored children enables stable
references without changing anonymous children.

## Asset paths

Ordinary component asset strings remain relative to the consuming project.
Opt into paths relative to the authoring JSON file with `prefab://`:

```json
"AudioPlayer": {
  "footsteps": {
    "clips": ["prefab://../assets/step1.wav", "prefab://../assets/step2.wav"]
  }
}
```

Rune expands the prefix into an absolute runtime path before inheritance and
overrides, so each value retains its original file's base directory. This also
works inside custom component objects and arrays. An override authored in a scene
resolves its prefixed strings relative to that scene. The prefix is reserved in
component string values; ordinary strings are left unchanged. Keep the source
files and referenced assets together when distributing a shared prefab. Resolved
absolute paths are runtime data; the source JSON remains hand-editable and unchanged.

## Hot reload and validation

The existing `hot_reload.enabled`, `scenes`, and `prefabs` settings watch all
transitive prefab references. Changes to nested files are picked up without
editing the parent. Invalid changes retain the live World and retry after repair.
Value-only reloads preserve handles when all entities have stable IDs and the
hierarchy/component membership is unchanged; structural edits rebuild the World.
Reacquire handles in scene-reload callbacks when a rebuild occurs.

`scene.Entity_Data` exposes the same composition fields for code-first
instantiation through `scene.instantiate_with_layers_at`. `prefab.load` returns
authored data; `prefab.resolve_scene` expands JSON using caller-owned scratch
storage. Neither API registers gameplay systems or saves edited files.

Run the headless controller-shaped composition fixtures, legacy replacement
checks, cycle/error checks, and nested reload tests:

```powershell
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run tools/prefab_validation -collection:rune=rune "-out:build/prefab_validation$exe"
```

The fixtures live under [tools/prefab_validation/fixtures](../tools/prefab_validation/fixtures).
The existing [Prefabs 2D example](../examples/prefabs_2d) remains a minimal
demonstration of the original component replacement behavior.
