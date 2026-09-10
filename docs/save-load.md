# Checkpoint saves

Rune saves selected gameplay state in versioned JSON slots. A checkpoint loads
the authored scene, reapplies saved progress, and recreates native runtime
resources. It supports game globals, progress across scenes, entity deletion,
runtime spawns, hierarchy changes, disabled entities, and custom state adapters.

Try [Checkpoint Saves](../examples/save_load_2d/README.md) for a two-room example.

## Setup and requests

Register game components with the ECS, then configure saves before `rune.run`:

```odin
import rune "rune:core"
import "rune:ecs"
import "rune:save"

Health :: struct {current: int}

ecs.register_component(&game.registry, "Health", Health, Health{100}, "Health")
rune.configure_saves(&game, save.Options{
    game_id = "my-game",
    game_version = 1,
})
save.register_component(rune.save_manager(&game), &game.registry, ecs.Transform)
save.register_component(rune.save_manager(&game), &game.registry, Health)

// From UI or gameplay callbacks:
rune.request_save(&game, "slot_1")
rune.request_load(&game, "slot_1")
```

Check each returned bool. A successful request means **queued**, with completion
at the next frame boundary, before simulation or drawing. Only one request can
be pending. Saves and loads work while paused. `rune.last_save_result` provides
an increasing `sequence`, the completed `action`, and `ok`.
`rune.last_save_error` explains failures, which also appear in the console.

By default, slots live under the OS user-data directory, then `game_id/saves`:
on Windows this uses local application data; on Linux it follows the toolchain's
XDG user-data directory. Supply `Options.directory` for a portable or test
directory; relative overrides resolve from the process working directory.
`save.slot_path` returns a frame-scratch path for a slot. Slot and game IDs allow
1–80 ASCII letters, digits, underscores, and hyphens.

## What persists

The engine records a baseline of scene-authored entities before startup systems.
Every nonempty scene entity ID participates in existence, enabled state, metadata,
and hierarchy persistence. IDs must remain unique and unchanged during play.
Entities without IDs are recreated from their scene defaults.

Component values are opt-in. Register a type with `save.register_component`, or
a JSON component name with `save.register_named`. On existing scene entities,
unregistered components keep their authored defaults. Registered components save
their current JSON values; removing one also persists its absence. Registration
applies to disabled entities too. Register policies once before gameplay and keep
them stable during a session. Changing policy names between releases requires
a migration.

Automatic serialization rejects raw `ecs.Entity` handles and pointers in typed
components. Use `ecs.Entity_Ref` for stable links, or supply an adapter. Reflected
fields marked `json:"-"` are excluded. Name-only JSON components have no type
information to inspect; game code must keep their data portable.

Runtime-created entities are ephemeral until explicitly tracked:

```odin
// Give the fully constructed entity a unique string ID first.
save.track_spawn(rune.save_manager(game), world, dropped_item)
```

Track each child separately. The save captures a tracked spawn's complete JSON
component configuration so rendering and other unregistered template components
can be reconstructed. A prefab can be instantiated normally and its resulting
entities tracked; the checkpoint stores their resolved data, not a dependency on
the original prefab. Destroying a tracked spawn removes it from future saves.
A saved entity's parent must also have a saved stable ID.

## Globals and scene travel

`save.set_globals` copies an arbitrary JSON value into the session. It is useful
for inventories shared between scenes, quest flags, currency, or unique-ID
counters. `save.globals` returns borrowed data; copy it before retaining it across
another save operation. World resources and process-global variables are not
serialized automatically.

Use `System.before_save` to copy game-owned global progress into the manager at
the capture boundary. It runs before writing a slot and before leaving a scene.
Read globals in startup/restore callbacks to initialize the new world's resources.

When saves are configured, `rune.change_scene` queues a scene change at the next
frame boundary. It captures the current room and restores any saved state for the
destination. `rune.request_saved_scene` explicitly requests the same operation.
Without save configuration, `change_scene` retains its existing immediate behavior.
Scene paths are project-relative; saves cannot select scenes outside that project.
In-memory scene travel does not write a slot; use `request_save` to persist it.

## Restore lifecycle

Rune parses and checks the slot, loads a candidate world, creates saved entities,
restores components and hierarchy, then invokes custom adapters. All saved entity
IDs and ordinary components exist before adapters run. Resolve `Entity_Ref` values
against this new world; old numeric handles are invalid.

An optional `Options.prepare` callback runs on the candidate world and document.
Use it to validate game-specific references or create world-owned resources.
Return false to reject the candidate. Prepare and adapter callbacks must limit
mutations to the candidate world; external side effects cannot be rolled back.
In a multi-room save, inactive rooms are instantiated and checked when visited.

Only after preparation succeeds does Rune call the old world's shutdown systems,
replace the world and session document, reset the fixed-step accumulator, and call
`System.on_save_restored`. It **does not call `System.start` during restoration**.
First visits to rooms still use `start`. Set both callbacks to the same procedure
when initialization is safe for both cases:

```odin
rune.register_system(&game, rune.System{
    name = "gameplay",
    start = enter_world,
    on_save_restored = enter_world,
    before_save = capture_progress,
    update = update_game,
    shutdown = leave_world,
})
```

Restore callbacks reacquire entity handles and initialize game-owned systems;
they should preserve restored component values. There is no fallback to `start`
or `on_scene_reloaded`. All systems needing setup on restore must opt in.
Failed preparation leaves the running world intact and calls no shutdown/restore
systems. A failed destination load still leaves the captured departure progress
in memory, while the current world continues running.

## Custom runtime state

Scene JSON snapshots do not include every controller, timer, or animation state.
Supply a `save.Adapter` with these signatures when those values matter:

```odin
capture :: proc(world: ^ecs.World, entity: ecs.Entity,
                allocator: mem.Allocator) -> (json.Value, bool)
restore :: proc(world: ^ecs.World, entity: ecs.Entity,
                value: json.Value) -> bool
```

Pass the adapter as the final argument to `save.register_component` or
`save.register_named`. The adapter owns the complete saved representation of that
component. Capture must be read-only. Restore must validate its input, copy any
retained strings/data into world-owned storage, and create the component if absent
(as it will be on a restored runtime spawn). Adapter order is unspecified; resolve
cross-adapter dependencies in `Options.prepare`. See the countdown timer adapter
in [save_validation](../tools/save_validation/main.odin).

## Versions, backups, and failure handling

Files carry independent `format_version`, `game_id`, and `game_version` fields.
Rune rejects a different game ID, unknown format, or newer game version. For an
older game version, provide `Options.migrate`:

```odin
migrate :: proc(document: ^save.Document, from, to: int,
                allocator: mem.Allocator) -> bool
```

The callback updates the in-memory document to the requested game version. Use
the supplied allocator for retained strings, arrays, and maps. Rune updates the
version on success; the on-disk slot changes only on a later save. Migrations can
rename entity IDs/components, update saved fields, or discard obsolete room state.

Writes serialize first, sync a temporary file, copy the previous slot to a synced
temporary backup, and use replacement renames for the backup and slot. A failed
write leaves the primary slot intact. Successful replacements retain the previous
slot as `<slot>.save.json.bak`. Use `rune.request_load(game, slot, backup = true)`
to recover it explicitly. This protects against partial writes; it is not a
guarantee against storage hardware failure or concurrent processes writing the
same slot. A manager and its slot directory have a single writer.

## Scope and validation

These are checkpoint saves. Physics contacts, controller jump/dash phases,
animation playheads, particle clouds, audio voices, and random-number generators
restart unless game adapters preserve the needed state. Assets are referenced by
path and rebuilt normally. This is not a deterministic mid-frame physics snapshot.
Scene hot reload remains an authoring operation and can change live state; the
demo disables it for repeatable save/load behavior.

The engine-owned scene loop handles scheduling. Low-level tools can use
`save.begin_scene`, `capture`, `write_slot`, `read_slot`, `prepare_scene`, and
`commit` directly, managing world lifetimes and safe simulation boundaries.

```powershell
odin run tools/save_validation -collection:rune=rune -out:build/save_validation.exe
odin run tools/save_validation -collection:rune=rune -out:build/save_validation.exe -- --runtime
```

Use an extensionless output path on Linux. The normal validation suite discovers
the headless tests; `tools/validate.ps1 -Runtime` includes the hidden-window tests.
Checks cover scene round trips, hierarchy, component removal, owned strings,
globals, adapters, backups, failed loads, migrations, and paused frame scheduling.
