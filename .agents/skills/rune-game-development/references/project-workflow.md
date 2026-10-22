# Game projects, builds, and verification

`RUNE_ROOT` is the Rune checkout; `GAME_ROOT` is the game folder containing
`project.json`. Source/doc paths below are relative to `RUNE_ROOT`. Commands
assume the stated working directory, not the installed skill's directory.
Use the current `toolchain.json` and source as the authority for changing pins.

## Create or identify a game

For a new independent game, use `tools/new_project.bat` or
`tools/new_project.sh`. They copy `templates/blank_project`, local schemas,
scene/input JSON, `publish.json`, `publish.assets.json`, and Windows/Linux build
helpers; they refuse to overwrite an existing destination. The initial scene is
empty, so a window showing only its background is expected. Add an active
Camera2D and drawable entities for Rune's
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
and build helpers. The generated entry point uses `rune.init_project()`, then
`rune.run(&engine)` for the startup scene. Development binaries in `GAME_ROOT/build/`
find `../project.json` relative to the executable, independently of CWD.
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

Use `--player` for an optimized Windows/Linux player executable. This adds
`-define:RUNE_PLAYER=true` and `-define:RAYLIB_SHARED=false`; it does not yet
package content. Stage the executable with adjacent `project.json` and the
project's complete content tree, preserving relative paths. Player startup never
falls back to a parent project or CWD. `--player --run` is rejected until staging
is implemented. The profile disables developer console/UI/commands/inbox,
captures, hot reload, engine gizmos, bridge debug grids/collider wireframes, and
FPS title updates, regardless of project settings. Assertions and runtime checks
remain; console diagnostics also reach stderr. Guard command registration
assertions with `when !rune.Player_Build`:
`console.register`, `console.execute`, and `console.enable_remote` return false
in player builds. Runtime console inspection below requires a development build.
See `docs/publishing.md` for the maintained plan and manual staging layout.

## Publish the game

The standalone application lives in `rune_publish/`; `rune_publish/README.md`
documents its direct locked builds, tests, CLI options, and exit codes.
Invoke it through the engine's compatibility launchers:
`tools/publish.bat --project <GAME_ROOT>` or
`sh tools/publish.sh --project <GAME_ROOT>`. Generated games include `publish.json`
and its local schema; existing games must add a config and adopt portable
startup. The config supplies ID/title/version/executable, enabled native targets,
explicit `content` files/directories, optional game `licenses`, and optional
build collections/typed defines/linker flags. Paths are game-relative; sibling
build-only source collections may use `../`. By default complete content trees
are copied. Opt into `prune.enabled` to keep the dependency closure from project
startup/input, `prune.roots`, dependency manifests, and all game licenses.
Declare code-loaded resources/custom-data edges explicitly; Rune does not scan
arbitrary Odin/JSON. Manifest `inputs` can hash source files/directories to reject
stale generated roots. Retain asset notices under `licenses` even when inside
prunable folders. Use `--dry-run` to validate selected content and inspect totals
before building. See `docs/publishing.md` for manifest/checksum semantics and the
package's `asset_pruning` report. Rune/r3d collections and player/static-raylib flags are reserved and
supplied by the publisher, independently of the game's copied build helpers.
Windows packages also use `-subsystem:windows` and audit the resulting PE GUI
subsystem so launching the player does not create a console window.

The default output is `GAME_ROOT/build/publish/<id>-<version>-<target>/`, plus an
adjacent Windows ZIP or Linux tar.gz. `--output` selects a fresh package directory;
command-line paths are relative to the caller. Both outputs must be absent.
The publisher stages content/notices, validates known references and every
recognized included scene, builds with the cooperative compiler lock, audits
native dependencies, hashes files into `manifest.json`, and creates the archive
before final no-replacement moves. Failed staging remains for inspection.
On Linux the output filesystem must support atomic no-replacement renames;
choose native Linux storage for `--output` if a WSL Windows mount rejects them.
It preserves empty directories and rejects unsafe/omitted references, case
conflicts, overlapping includes, symlinks, and Windows reparse/junction ancestors.

Windows requires MSVC and an official installed AMD64 VC CRT for the bundled
native libraries. The publisher can discover `VCToolsRedistDir` or the installed
VC-qualified Visual Studio redist; `--windows-runtime-directory` and optional
`--windows-runtime-license` override it. Only audited allowlisted required CRT
DLLs are copied; arbitrary native plugins are unsupported. Linux requires
`flock`, `readelf`, `mktemp`, and `tar`, and defaults to a glibc 2.39 ceiling. Build with a
compatible SDK/sysroot; raising `--glibc-max` records a different requirement and
does not preserve the older baseline. System sonames/C++ symbol requirements
remain target requirements. No extra scripting runtime is required by publishing.

`--odin`/`ODIN` selects the game compiler; the bootstrap launcher needs Odin on
PATH. Both must follow `toolchain.json`. Typed strings use Odin's single-quote
define convention. The tested Windows compiler cannot preserve literal double
quotes inside argument values; the publisher rejects them rather than silently
changing defines/linker flags. Validate custom options on the intended host.

Verify file hashes/archive structure, then move/extract the package and launch
from an unrelated working directory with compiler/checkout paths unavailable.
Exercise scene transitions, prefab/model sidecars, input, writes to user storage,
and the actual rendering path. The manifest's native audit and a successful
build do not qualify older Linux systems, physical hardware, or audible output.
See `docs/publishing.md` for exact commands, config fields, and validation limits.

## Declare code-loaded resources

Whenever game code adds, changes, or removes a file load, maintain its publishing
dependency manifest in the same change. This includes later scene transitions,
prefabs spawned from code, asset-manager calls, `rune.resource_path`, and direct
raylib/OS reads of bundled resources. Resources named only in custom JSON fields
also need declarations. Runtime-created saves, settings, and user-selected
external files are not bundled resource dependencies.

Use the game's existing manifest registered in `publish.json` under
`prune.manifests`. New games already register `publish.assets.json` with an empty
`roots` list and pruning disabled. If none exists, create
`GAME_ROOT/publish.assets.json` with `version: 1` and a `roots` array, then append
its filename to `prune.manifests` when the game has a publishing config. Preserve
the current `prune.enabled`
choice; maintaining declarations does not require enabling pruning. If there is
no publishing config yet, keep the manifest and identify its required wiring.

For example, a game that loads a cursor, a later scene, and runtime-selected
enemy textures can declare:

```json
{
  "version": 1,
  "roots": [
    "assets/ui/cursor.png",
    "scenes/dungeon.scene.json",
    "assets/enemies/"
  ]
}
```

Paths are case-correct, portable, and relative to `GAME_ROOT`, even when the
manifest lives in a subdirectory. They must be covered by `publish.json`'s
`content` inventory. Directory roots keep their entire tree; use specific files
when the set is known, or a bounded directory for computed filenames. Globs are
not supported. Known scene/prefab/model dependencies are followed recursively,
so their recognized asset references need not be repeated. The manifest itself
is source metadata and need not be shipped in `content`.

Use `roots` for code-loaded resources. Use `dependencies` for custom data edges
such as a retained level descriptor referring to a binary data file; an edge is
followed only after its source file becomes reachable. Do not use Odin source
files as dependency keys: those files normally are not package candidates.
Reuse entries shared by other load sites; remove obsolete paths only after
checking that no remaining code or data needs them. For generated manifests,
update the generator or its source declarations and regenerate; refresh optional
`inputs` hashes after relevant source changes. See `docs/publishing.md` for the
manifest format and `rune_publish/pruning.odin` for traversal and hash semantics.

For games with pruning enabled, run the publish launcher with `--dry-run`, then
exercise the changed loading paths in the published game. A dry run checks
declared references; it cannot detect missing declarations in arbitrary code.
With pruning disabled, manifests are not traversed, so a successful dry run does
not validate their completeness or contents.

## Continue development

`rune.init_project(path)` accepts an explicit executable-relative layout;
`rune.init(path)` retains explicit CWD-relative/absolute caller control. Both
retain an absolute `engine.project_directory` after successful initialization.
Pass that root to `r3d_bridge.init`; use
`rune.resource_path(&engine, "assets/settings.json")` for game-owned reads and
delete the returned owned path with its allocator. Absolute resource paths and
parent traversal remain supported for tools; this helper is not a package
containment check. Raw relative OS/raylib file reads still depend on CWD.
Configured saves default to OS user-data/game ID/saves; keep custom settings,
rebinding saves, and file logs in writable user storage too. Startup does not
change the process working directory or redirect arbitrary game writes.
The Windows/Linux startup/profile and publishing validation contexts and their
runtime/ABI limits are recorded in `docs/publishing.md`, including extracted
packages and the explicit glibc ceiling used for Ubuntu 26.04 checks.

Use `rune.init_project(defer_window_show = true)` or
`rune.init(path, defer_window_show = true)` to keep asset loading and saved
display preferences hidden. The default is false and reveals before returning.
Built-in scene/callback loops reveal after their first completed `EndDrawing`;
custom loops call `rune.show_window(&engine)` after their first full
`EndDrawing`. It returns success and later calls do nothing, including when the
game deliberately hides the window after startup. Windowed/borderless changes
apply while hidden; exclusive fullscreen waits until reveal because its Win32
transition forces visibility. Query `rune.window_mode(&engine)` for the requested
startup mode, including queued fullscreen; the no-argument query reports native
state. See `docs/display.md` and `rune/core/window.odin`.

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

In the 2026-10-21 managed Windows sandbox, default temporary directories allowed
test-file creation but denied the atomic rename used by console replies.
Core/console tests passed with process-scoped `TEMP` and `TMP` pointing to a
temporary directory under ignored `build/`. If the same permission error occurs,
verify the failing rename and use that scoped test environment; restore the
variables afterward. Do not treat a sandbox rename denial as a runtime regression.

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
