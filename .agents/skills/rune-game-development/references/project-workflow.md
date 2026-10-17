# Game projects, builds, and verification

`RUNE_ROOT` is the Rune checkout; `GAME_ROOT` is the game folder containing
`project.json`. Source/doc paths below are relative to `RUNE_ROOT`. Commands
assume the stated working directory, not the installed skill's directory.
Use the current `toolchain.json` and source as the authority for changing pins.

## Create or identify a game

For a new independent game, use `tools/new_project.bat` or
`tools/new_project.sh`. They copy `templates/blank_project`, local schemas,
scene/input JSON, and Windows/Linux build helpers; they refuse to overwrite an
existing destination. The initial scene is empty, so a window showing only its
background is expected. Add an active Camera2D and drawable entities for Rune's
automatic 2D scene rendering, or explicitly integrate 3D rendering.

Example from `RUNE_ROOT` on Windows, adapting the destination to the request:

```powershell
$runeRoot = (Get-Location).Path
.\tools\new_project.bat --path ../MyGame --name 'My Game'
Push-Location ../MyGame
try {
    .\build.bat --rune-root $runeRoot
} finally {
    Pop-Location
}
```

Equivalent creation/build from `RUNE_ROOT` on Linux:

```sh
rune_root="$PWD"
sh tools/new_project.sh --path ../MyGame --name 'My Game'
cd ../MyGame
sh build.sh --rune-root "$rune_root"
```

For existing games, inspect their own `project.json`, `main.odin`, local schemas,
and build helpers. The generated entry point initializes `project.json`, then
uses `rune.run(&engine)` for the startup scene. It must run from `GAME_ROOT`.
Examples instead commonly initialize `examples/<name>/project.json` from
`RUNE_ROOT` and can import `examples/shared` or neighboring assets. Reuse their
patterns; do not assume copying an example folder produces an independent game.

Ordinary component asset paths are project-relative; the `prefab://` exception
resolves from the authoring JSON file as described in
[gameplay-and-scenes.md](gameplay-and-scenes.md). Keep scenes, textures, sounds,
input mappings, and prefab references within the game's intended layout. Learn
format-specific relative-path rules from its guide and loader. The generator
rewrites `$schema` references to local game schemas; verify those paths when
moving files. `docs/components.md` and `schemas/` describe authorable fields.

## Build and run the intended source

Install the compiler and native dependencies described in `README.md` and
`docs/linux.md`, matching `toolchain.json`. Initialize the pinned submodules as
documented. Rune's build helpers prepare the recorded R3D compatibility patch;
for manual commands use the appropriate `tools/prepare_r3d.bat` or `.sh` first
when needed. Do not discard expected prepared submodule changes.

Run the game's `build.bat --rune-root <engine>` or
`sh build.sh --rune-root <engine>` from `GAME_ROOT`; `RUNE_ROOT` can also supply
the engine path. Add `--run` to launch after building, `--release` for an
optimized build, and `-- <game arguments>` for runtime arguments when running.
Outputs are `GAME_ROOT/build/game.exe` on Windows and `GAME_ROOT/build/game` on
Linux. Use optimized builds for profiling; optimization does not disable runtime
checks or configured JSON hot reload.

For manual Odin commands, use Rune's compiler-lock wrappers
`tools/odin.ps1`, `tools/odin.bat`, or `sh tools/odin.sh`; supply
`-collection:rune=<RUNE_ROOT>/rune` and an output under the game's `build/`.
Manual Windows commands also need `-linker:msvc` with the recorded toolchain;
the wrappers do not add it. Linux omits that flag. Build interactive programs,
then launch the successful output separately to release the compiler lock.

Importing `rune:r3d_bridge` additionally needs
`-collection:r3d=<RUNE_ROOT>/third_party/r3d-odin`. The blank template's current
build helpers supply only the Rune collection. When adding the bridge, update
both game helpers: quote the collection argument using `%engineRoot%` in the
batch helper and `$engine_root` in the shell helper. Follow the current
`examples/hello_3d` build guidance and dependency setup; do not copy its
example-relative asset root into a standalone game.

Generated helpers and schemas are copies. On an engine upgrade, compare the
game's copies with current templates/schemas and deliberately carry over relevant
fixes, including Windows linker changes. Do not assume updating Rune refreshed
files already copied into a game.

## Verify an authored game

Build `tools/project_validator` from `RUNE_ROOT` using the normal compiler wrapper
and flags, then pass the game's `project.json` path to its executable. It follows
startup scene/prefab/asset references without creating a window. Structural
validation cannot prove that registered game-specific component types or
gameplay behavior work: build and run the actual game too. Check registration,
camera selection, missing assets, input mappings, pause, and reload as relevant.

Odin source changes require a rebuild. JSON reload depends on the game's
`hot_reload` settings; invalid reloads must be distinguished from the previously
valid scene remaining visible. Project settings, input mappings, and audio-file
contents are not automatically reloaded: restart or use the supported runtime
API for the specific change. Value-only scene reload preserves runtime values
whose authored data did not change; it does not reset the whole simulation.
See `README.md` (Development hot reload) and `rune/core/core.odin`. Existing
launcher prebuilt binaries may be stale. Record the actual game, source
snapshot, build result, and runtime checks used.

Use focused engine validators only where they help diagnose a game integration
problem; `README.md`, `docs/linux.md`, and `docs/release.md` describe wider engine
checks. Clean up only processes and scratch directories created for the task.
A virtual display is graphics coverage, not proof of physical controller,
desktop GPU, or audible behavior.

## Inspect gameplay through the console

Press backtick to open the in-game console. Tab completes case-sensitive command
names and supported arguments; Shift+Tab cycles matches backward. Engine commands
suggest live entity IDs, component names, `set` field paths, input actions and
fixed command options. Matching suggestions appear above the input as you type;
Up/Down moves the highlight without editing the command, and Enter accepts the
highlighted token. Click any visible suggestion to accept that row directly.
Acceptance replaces only the current token and hides the list until an edit or
Tab, so another Enter executes. Ctrl+Up/Down always browses command history;
Up/Down also browses history when suggestions are hidden or unavailable. Completion quotes names
containing spaces when needed.
Custom command names participate automatically; pass an optional
`console.Completion_Proc` to `console.register` for argument suggestions. Its
callback can run during suggestion refreshes and token completion. Keep it a
read-only query of live game state. Request and candidate strings are borrowed for the
current call; do not retain scene pointers or request data across reloads.
Built-in completions do not suggest file paths or arbitrary JSON values. See
`docs/runtime-console.md` and `rune/console/completion.odin` for the controls and
callback contract.

With the console open, left-click a scene object outside the panel to print its
ID, name, hierarchy, and current component values without editing the command
draft or history. Picking uses the attached scene's active cameras and rejects
letterbox bars. A supported 3D hit takes priority over a 2D hit; 2D objects follow
draw order. It remains available while paused, except while a `step`, `profile`,
or local inbox reply is pending. Queries use geometry bounds rather than visible
pixels. Amber corner brackets follow the picked entity's own rendered bounds,
independently of F3 gizmos. The native debug overlay draws after game UI and is
excluded from `capture`; it does not change game materials, depth state, or scene
data. Closing the console, clicking empty canvas, replacing the attached scene,
or deleting the entity clears the selection. Disabling the entity or an ancestor
hides its brackets while retaining the selection. See
`docs/runtime-console.md` (Picking scene objects),
`rune/core/debug_picking.odin`, and the picking notes in
[rendering-ui-audio.md](rendering-ui-audio.md#choose-collision-queries-or-rendered-picking)
for supported renderers and custom drawing limits. Callback loops have no
attached scene to pick.

Use `@picked` in entity arguments to `inspect`, `set`, `enable`, `disable`, or
`navmesh on`; it resolves the live selection when the command runs and participates
in entity, component, and field completion. It is reserved before scene IDs.
The alias and completion remain available after `disable @picked`, allowing
`enable @picked` to restore the object's local activation flag. Disabled
ancestors still keep it inactive; brackets return when it is active and visible.
An invalid selection reports an error without changing the scene. Custom engine
commands can query `rune.debug_picked_entity(game)` for a handle plus validity flag.
Do not keep the handle across scene replacement.

The console temporarily shows and releases the mouse, then restores the desired
gameplay cursor mode. After `rune.init`, use `rune.set_cursor_mode(game, .captured)` for first-person
look, `.hidden` for a hidden free cursor, or `.visible` for a visible free cursor.
Mode changes while the console is open update the restore mode; query it with
`rune.cursor_mode(game)`. Direct raylib hidden/captured modes cannot be distinguished
by its public query, so use Rune's setter for exact restoration. Mapped gameplay
input remains captured through the closing frame and recapture mouse deltas are
discarded. Raw raylib readers must still respect console focus. `rune.begin_frame`
owns this for custom loops; loops calling `console.update` directly use
`rune.sync_console_cursor` before and after it and must handle their own next-sample
mouse-delta suppression. Prefer `rune.begin_frame` for the complete input policy. See
`docs/runtime-console.md` (Cursor ownership) and `rune/core/cursor.odin`.

Use `docs/runtime-console.md` for repeatable runtime inspection without keyboard
focus. Launch the built game from `GAME_ROOT` with an inbox unique to that process:
`build/game.exe --console-dir=build/console/inspection` on Windows, or
`./build/game --console-dir=build/console/inspection` on Linux. Keep the in-game
console closed when testing gameplay input, since its capture suppresses actions.

From a second terminal in `GAME_ROOT`, with `$runeRoot` resolved to `RUNE_ROOT`:

```powershell
$reply = & "$runeRoot/tools/console.bat" --directory build/console/inspection --command 'status' --json | ConvertFrom-Json
$reply.ok
$reply.data
```

On Linux the equivalent helper is `sh "$rune_root/tools/console.sh"` with the
same arguments. Check each reply's `ok` and parse structured `data`; JSON key
order and human-readable log formatting are not contracts. Pass each line below
as a separate `--command` value, adapting entity IDs and mapped action names:

```text
pause
entities
inspect player Transform
input move_right press
step 5
input move_right release
step 1
capture build/captures/after-step.png
input move_right clear
resume
```

`step` advances simulation while remaining paused. `release` forces an action up;
`clear` returns it to physical input. Restore injected actions and the intended
pause state when done. Open the returned capture path to inspect the completed
frame; its metadata identifies the scene and simulation step. `step`/`profile`
reply after completion, so adjust `--timeout-seconds` when needed. A timeout can
leave a claimed command running; inspect the result before repeating it.

`set` changes runtime fields and `reload` discards runtime scene edits. To persist
an edit, change source JSON explicitly. Entity inspection/edits require the
scene-owning loop; the low-level callback loop supports only the applicable
timing, input, logs, profiling, and capture operations.
