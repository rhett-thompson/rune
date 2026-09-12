# 3D character interactions

`Interactor3D` defines a character's reach and facing cone. `Interactable3D`
marks doors, pickups, characters, switches, or other usable objects. Both need
a `Transform`. Built-in registration, scene JSON, typed mutations, hot reload,
and save snapshots support these components.

```json
"Interactor3D": {"range": 3, "half_angle": 65}
```

```json
"Interactable3D": {
  "prompt": "Talk to guide",
  "offset": [0, 1.2, 0],
  "hold_seconds": 0.75,
  "enabled": true
}
```

Offsets use world axes and world units, added to the entity's accumulated
Transform position. Rotation and scale do not alter them. The caller supplies
the character's eye/reach position and facing direction each update. For an
orbit camera, use the character's position for reach rather than the camera's.

`find_interaction_3d(world, actor, origin, forward)` selects the most centered
visible target, breaking ties by distance and then entity handle. Selection
checks full 3D distance, the facing cone, component/entity enablement, and layer
masks. A collider is optional on the target. Solid physics geometry, including
collision-enabled terrain, blocks visibility; sensors and the actor's own
collider are ignored. A hit on the target or its children counts as visible.
Terrain must have been synchronized through the usual asset/physics lifecycle.

| Component | Field | Default |
| --- | --- | --- |
| Interactor3D | `range` | 3 world units |
| Interactor3D | `half_angle` | 65 degrees, allowed 0–180 |
| Interactor3D | `target_layers` | All 64 layer bits |
| Interactor3D | `obstruction_layers` | All 64 layer bits |
| Interactor3D | `require_line_of_sight` | true |
| Interactable3D | `prompt` | "Use" |
| Interactable3D | `offset` | [0, 0, 0] |
| Interactable3D | `hold_seconds` | 0 (instant press) |
| Interactable3D | `enabled` | true |

Layer fields are numeric bitmasks, matching physics queries. Initialize typed
values with `Default_Interactor_3D` / `Default_Interactable_3D`; an empty Odin
struct has zero fields, while an empty JSON object uses registered defaults.

Keep one `Interaction_State_3D` per character, then call once per gameplay frame:

```odin
activated := ecs.update_interaction_3d(
    world, &interaction, player, eye_position, forward,
    input.is_down(rune.input_state(game), "interact"), game.delta_time,
)
if activated != 0 {
    // Open a door, collect an item, start dialogue, etc.
}
```

`state.focus` contains the selected entity and world-space point;
`state.progress` is hold completion from 0 to 1. Read the target's component for
its prompt and draw it using your UI. Component strings are borrowed; do not
retain them across mutations or reloads. State contains no borrowed memory.

Activation returns exactly once per press. Release, loss of focus/range/sight,
disabled or destroyed targets, and edits to either interaction component cancel
holds. A held button cannot automatically activate a newly focused target.
After completion or cancellation, release before trying again. Use gameplay
time and cancel holds while menus, pause, or window focus suppress input; retain
the current button state in `was_down` to avoid activation on resume. Reset
transient state when replacing a scene or restoring a save.

The engine intentionally leaves effects in game code. It does not create an
inventory, dialogue tree, animation, or networking system. Persist those results
as scene/component state; in-progress input state stays transient. Selection
scans interactables and uses point visibility rather than swept-volume reach.

The [third-person example](../examples/third_person_3d/README.md) demonstrates a
key-locked animated door with collision and blocked-close checks, a brass-key
pickup and inventory HUD, and a guide with a hold-to-talk prompt. F5/F9 save and
restore collected items, inventory, and explicit door state. The example's
game-owned inventory helpers and save setup can be adapted for other games;
the engine's interaction API remains independent of item and door rules.
Its HUD uses the shared Inter font. Run regression
checks from the repository root:

```powershell
odin test examples/third_person_3d -collection:rune=rune -collection:r3d=third_party/r3d-odin -out:build/interaction_tests.exe
```
