# 3D trigger zones

`Trigger3D` creates a nonblocking box or sphere volume with `Enter`, `Stay`, and
`Exit` events. It detects native physics colliders and `CharacterController3D`
capsules, including their current crouch height. No collider or rigid body is
required on the zone itself. Objects with only a Transform are not participants.

```json
"Transform": {"position": [0, 1, 0]},
"Trigger3D": {"shape": "box", "size": [3, 2, 3], "layers": 4}
```

For a sphere, use `"shape": "sphere", "radius": 1.5`. `size` contains full box
dimensions. Both size and radius must be positive and finite; omitted values
use the defaults below. `layers` is a numeric target bitmask: `4` accepts entities
on layer index 2. The trigger entity's own layer does not filter participants.

| Field | Default | Meaning |
| --- | --- | --- |
| `shape` | `box` | `box` or `sphere`; typed serialization also accepts 0 or 1. |
| `size` | [2, 2, 2] | Full box dimensions. |
| `radius` | 1 | Sphere radius. |
| `offset` | [0, 0, 0] | Unscaled world-axis offset from the accumulated Transform position. |
| `layers` | All 64 bits | Accepted participant layers. |
| `enabled` | true | Disable detection while leaving the zone's visuals enabled. |
| `include_sensors` | false | Whether ordinary sensor colliders count as participants. |

Boxes remain aligned to world axes, even if the Transform is rotated. Dimensions
inherit the absolute product of hierarchy scales; spheres use the largest scale
axis. A zero scale disables detection. Positions follow Rune's additive
hierarchy translations. Both geometry dimensions and participants use full XYZ.

Register built-in components normally. The engine samples zones **after physics
and before `post_physics` callbacks**, once per fixed tick:

```odin
after_physics :: proc(game: ^rune.Engine, world: ^ecs.World) {
    for event in ecs.trigger_events_3d(world) {
        switch event.kind {
        case .Enter: // First tick overlapping this zone.
        case .Stay:  // Every subsequent tick while overlapping.
        case .Exit:  // First tick no longer overlapping.
        }
        // event.trigger identifies the zone; event.other is the participant.
    }
}
```

Events are deduplicated by zone/entity pair and sorted by those entity handles.
A pair emits Enter or Stay on a given tick, never both. Leaving a zone, moving
the zone away, changing its filter, disabling/removing its component, disabling
a parent, or destroying either entity produces one Exit on the next update.
An Exit can contain a destroyed handle; check `ecs.is_alive` before accessing it.
Targets with several colliders still produce only one event per pair.

`trigger_contains_3d(world, zone, other)` queries membership from the most recent
sample. Event slices are borrowed until the next update, reset, or World
destruction. Consume them in `post_physics`, since a rendered frame can contain
several fixed ticks. Headless hosts call `update_triggers_3d(world)` themselves
after physics. Pausing the engine freezes detection along with physics.

Membership and event history are World-owned runtime data. They are freed on
destruction and are not saved. `reset_triggers_3d(world)` quietly clears history;
the next sample emits fresh enters for any overlaps. Save game outcomes such as
an activated checkpoint separately, and make enter handlers safe to repeat after
a scene reload or checkpoint restore.

Detection samples current overlaps rather than sweeping movement between ticks.
A very fast object can cross a narrow zone between samples. Choose adequate zone
thickness or implement a swept query for that use case.

The [third-person example](../examples/third_person_3d/README.md) has a green box
checkpoint and a red sphere hazard, filtered to the Player layer. The checkpoint
sets a safe feet position; the hazard deals health damage while overlapping,
respecting a per-character protection timer. At zero health, a short death
countdown calls `character_controller_3d_teleport` to respawn there with full
health, clearing velocity, moving-platform support, and buffered input.
Teleporting does not sweep or validate destination clearance: the game authors a
safe spawn. Inventory and door state survive respawns. F5/F9 save/load the selected
`RespawnPoint`, health, and remaining protection/death timers along with the rest
of the checkpoint. The effects live in game code; other games can consume the
same trigger events for different rules.

Regression checks:

```powershell
odin test examples/third_person_3d -collection:rune=rune -collection:r3d=third_party/r3d-odin -out:build/interaction_tests.exe
```
