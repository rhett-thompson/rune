# Gameplay and scenes

Author game files under `GAME_ROOT`; read engine APIs, schemas, and examples
under `RUNE_ROOT`. Repository paths below are relative to `RUNE_ROOT`; authored
paths follow the relevant game file's loader, not this skill's location.

## Author component data deliberately

Use `docs/components.md` and `schemas/scene.schema.json` to choose authorable
fields. Entity IDs, hierarchy, layers, and activation belong outside
the `components` map. JSON omission defaults are not Odin zero values. For typed
creation, start with helpers such as `ecs.default_transform()` and override the
desired fields; a supplied typed value supplies every field. Do not copy runtime
inspection fields such as solver state or playback cursors into scene JSON.

For reusable entity trees, follow `docs/prefabs.md`. Each `prefab` path is
relative to the JSON file containing that reference. `components` replaces whole
component blocks; `component_overrides` merges object fields, with arrays/scalars
replaced. Use `child_overrides` for named child paths. Ordinary component asset
strings resolve from the consuming game's root. A `prefab://` prefix instead
resolves from the JSON file authoring that value, before inheritance/overrides;
an override authored in a scene therefore uses that scene file's directory.
This applies inside custom component objects/arrays too. Keep shared prefabs
with their referenced assets; resolved absolute paths are runtime data, not
portable source paths. See `rune/prefab/resolve.odin`.

Prefab child IDs are local: an instance `player` with child `camera` produces
`player/camera`; identified children need identified ancestors. Entity-reference
strings inside components are not automatically rewritten for each instance.
Resolve a local path with `ecs.find_prefab_child(world, instance, "camera")`, or
supply an explicitly qualified scene ID for `Entity_Ref`. Do not use display
names as IDs. See `docs/prefabs.md` and `rune/ecs/prefab_references.odin`.

Use `ecs.get`, `ecs.set`, `ecs.add`, and typed `ecs.query`/`query2`/`query3` for
normal gameplay. Check returned success/found values. Getters return copies;
their strings and collections borrow component storage. Treat those references
as read-only and reacquire them after replacement, removal, or reload. Supply
owned replacement collections to setters, which copy them. Direct writes into
World maps bypass validation, change notifications, and native/cache updates.
Normal queries omit disabled entities; use the explicit `include_disabled`
argument when needed. `ecs.compact_scene_storage` also invalidates borrowed scene
JSON, strings, and metadata while entity handles remain valid; call it only at a
safe point and reacquire those borrows. See `rune/ecs/component_api.odin` and
`rune/ecs/storage_maintenance.odin`.

`AudioPlayer` is repeatable: its JSON object contains named instances. Use
`ecs.get_audio_player`/`ecs.set_audio_player` and address playback by entity plus
instance name through `rune.play_audio`/`rune.stop_audio`; single-instance typed
access is not its interface. See `docs/audio-mixer.md`.

## Register before loading

After `rune.init`, register custom gameplay structs and their defaults with
`ecs.register_component(rune.component_registry(&game), ...)`, then register
systems before `rune.run(&game)` loads the startup scene. Unregistered component
names and unknown custom fields fail loading. Follow
`examples/hello_world/main.odin`.

## Put behavior in the correct phase

The scene-owning loop in `rune/core/core.odin` runs systems
in registration order within each phase. `start` runs after a World exists;
`shutdown` runs in reverse order on engine-managed scene travel, saved-world
replacement, and loop exit. Structural hot reload follows the separate callback
path described below.

- `ui_update` runs before simulation, including while paused.
- `fixed_update` precedes navigation and native physics. Use
  `game.fixed_delta_time`; consume contact/sensor events in `post_physics` after
  each step, rather than once per rendered frame.
- `update` uses `game.delta_time`. Sprite animation follows it; consume sprite
  markers in `post_animation` before particles and audio are serviced.
- `pre_draw`, automatic 2D scene rendering, `draw`, and gizmos draw into the
  game canvas. `draw_ui` follows canvas presentation at native UI resolution.

The engine advances supported physics, 3D navigation, sprite animation,
particles, lifetimes, and audio; avoid advancing them again in game callbacks.
Components still describe data: Orbit/Rotator and other explicitly documented
behaviors require game systems. The optional r3d bridge's rendering/animation
must be integrated explicitly. Use
`docs/components.md` and
`examples/animation_events_2d/main.odin`
instead of assuming every attached component runs automatically.

## Separate frame input from fixed-step commands

input.odin (`rune/input/input.odin`) samples actions once per rendered
frame; `pressed`/`released` read cached state rather than consuming events. A
frame can execute zero or several fixed steps. For a one-shot that must neither
repeat across steps nor disappear before the next step, latch it once in a frame
callback and consume it once in `fixed_update`. Define when pause or menus clear
pending commands. Continuous movement can read held actions each step.

Call `input.capture` every frame a modal menu owns gameplay input. For UI actions
during pause, use the frame APIs described in
`docs/ui.md`; raw raylib input
bypasses capture. Mouse deltas are displacement, while stick look values are
rates; apply time accordingly (`docs/gamepads.md`).

After `rune.init` creates the window, use
`rune.set_cursor_mode(game, .captured)` for locked, hidden mouse look,
`.hidden` for a hidden free cursor, or `.visible` for a visible free cursor.
`rune.cursor_mode(game)` returns the desired gameplay mode. The console temporarily
uses a visible free cursor and restores the desired mode on close, including mode
changes requested while open. Keep gameplay capture flags unchanged during that
temporary override. Mapped input is captured through the console's closing frame;
recapture mouse deltas are discarded before look resumes. Raw raylib readers must
still respect console focus. Rune's setter preserves the distinction between
hidden-free and captured modes that raylib's public cursor query cannot report.
See `docs/runtime-console.md` (Cursor ownership) and `rune/core/cursor.odin`.

Cursor policy tests are in `rune/core/cursor_test.odin`; the hidden-window
`tools/debug_console_validation --runtime` fixture checks visible/hidden/captured
mode restoration, console input capture, live mode changes, and the next sampled
mouse delta. Verified with static and pinned shared raylib builds on Windows,
OpenGL 3.3/NVIDIA, at 1000x800 logical and framebuffer resolution. These checks
observe raylib visibility and Rune's tracked mode; they do not establish focused
native pointer lock, physical mouse/click
behavior, or physical HiDPI coverage.

Raylib closes the window on Escape by default. If Escape belongs to a game menu,
call `rl.SetExitKey(rl.KeyboardKey(0))` after initialization, as in
`examples/clay_ui/main.odin`. Rune also exits after a focused controller holds
START for one second, including while paused and without action mappings.
Disable that behavior with `rune.set_gamepad_exit(&game, false)` when the game
owns START. Input capture does not disable either exit mechanism; Rune separately
consumes Escape while its console is open. See `rune/core/gamepad_exit.odin` and
`rune/core/core.odin`.

## Rebind through owned configuration drafts

For settings menus, follow `docs/input-rebinding.md` and
`examples/runtime_rebinding/main.odin`. Use `input.clone` for an independently
owned draft; a shallow `Input` copy aliases its arena. Apply changes with
`input.replace_configuration`, which clones while retaining the source, or
`input.move_configuration`, which transfers ownership and zeros the source on
success. Check return values and destroy owned drafts with `input.destroy`.
Successful installation resets sampled/injected input and captures gameplay
queries for the rest of that frame; normal sampling resumes on the next update.

`input.save` writes the originally loaded input path, which cloning preserves.
Choose a deliberate user-preference destination and persistence policy instead
of accidentally overwriting authored defaults. If saving must succeed before
the live controls change, prepare and save the owned draft first, then transfer
it with `input.move_configuration`. See `rune/input/rebinding.odin` and
`rune/input/input.odin` for ownership and persistence behavior.

## Configure controllers and replace persistent requests

Use `docs/character-controller-2d.md` and `docs/character-controller-3d.md` before
assembling a player. Check `ecs.character_controller_2d_ready` or
`ecs.character_controller_3d_ready` when a motor stays inactive:

- 2D requires a dynamic `RigidBody2D` and solid vertical `CapsuleCollider2D`;
  additional solid shapes invalidate the motor, while sensors are allowed.
- 3D requires an unparented unit-scale entity whose position is its feet, with
  no `RigidBody3D`, `BoxCollider`, `SphereCollider`, or legacy
  `CharacterController`. Keep the camera separate. Its query capsule is absent
  from native physics ray/overlap results; use
  `ecs.character_controller_3d_raycast` for projectile hits and compare with world
  hits. `Trigger3D` explicitly detects these capsules.

Movement and crouch commands persist until replaced; the motors do not read
action mappings. Send neutral movement and the intended crouch/sprint state on
release or menu capture, rather than skipping the control callback and retaining
old commands. Capturing input alone leaves submitted motor requests intact. If a
menu should stop a 3D dash, also call `ecs.character_controller_3d_cancel_dash`;
free motion needs zero velocity to hover. Keep the edge-latching policy above for
jump/dash requests. See `rune/ecs/character_controller_2d.odin`,
`rune/ecs/character_controller_3d.odin`, and
`rune/ecs/character_controller_3d_dash.odin`.

## Reacquire scene state and preserve restored progress

Give authored entities stable nonempty IDs. Structural hot reload replaces the
World without calling system `shutdown`, then invokes `on_scene_reloaded`;
reacquire cached handles there and avoid depending on `shutdown` to clean up
external state for this path. Value-only reload preserves handles and does not
invoke that callback. See `rune/core/core.odin` and `README.md`, Development hot
reload.

Without configured saves, `rune.change_scene` replaces the World immediately
after successful loading. With saves, travel queues for a frame boundary and
revisited rooms use the restore lifecycle. Do not retain handles from the old
World across either transition.

Configure saves and component policies before running. Authored entities with
stable IDs retain existence, metadata, enabled state, and hierarchy; their
component values require `save.register_component`/`save.register_named`.
Unregistered values use authored defaults. Runtime spawns need unique stable IDs
and `save.track_spawn` for each entity, including children; saved parents also
need saved IDs. Tracked spawns retain their complete JSON component configuration
for reconstruction, including unregistered template components; registered
adapters provide custom representations. See `rune/save/save.odin` and
`rune/save/snapshot.odin`.

Copy game-owned globals into the manager with `save.set_globals`, normally in
`before_save`. World resources and process globals are not captured automatically.
Saved scene travel updates the in-memory session; call `rune.request_save` to
write a slot. Only one request can be pending. A successful request return means
accepted, not completed: record the previous `rune.last_save_result` sequence and
wait for it to change after a frame boundary before reading `ok`/`action` and
`rune.last_save_error`. The sequence advances on both success and failure. See
`rune/core/saves.odin`.

Restoration invokes `on_save_restored` instead of `start`, with no fallback to
`start` or `on_scene_reloaded`; initialize handles/resources while preserving
restored values. Register each applicable callback. Checkpoints omit transient
physics contacts, controller phases, animation playheads, audio voices, and RNG
state; reconstruct needed runtime state explicitly.
Never persist raw `ecs.Entity` handles. `ecs.Entity_Ref` borrows its ID string,
so retain a literal or game-owned copy across World replacement. Follow
`docs/save-load.md` and
`examples/save_load_2d/main.odin`.
