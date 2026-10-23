# Runtime console commands

These tools are available in development builds, including optimized `--release`
builds. The player profile (`--player`, or `-define:RUNE_PLAYER=true`) disables
console UI, command registration/execution, captures, and the local command
inbox. `--console-dir` cannot enable it. Diagnostic logging remains available
through `rune.developer_console`; player logs also go to stderr. See
[game publishing](publishing.md) for startup and build-profile details.

## In-game console

Press backtick to open the console and Escape or backtick to close it. The
overlay uses Inter typography, rounded navy panels, and the game UI's teal
accent. Warning and error messages have distinct colors.
Opening it releases and shows the mouse so first-person games can use suggestions
and pick objects; closing restores the gameplay cursor mode.

- Left/Right moves the caret; Home/End moves to the start/end of the command.
- Backspace removes the previous character; Delete removes the next. Both
  respond immediately to a tap and repeat when held.
- Ctrl+Left/Right and Ctrl+Backspace/Delete move or delete a command token.
- Click within the input to place the caret. Long commands scroll horizontally.
- Drag to select command text or console output. Shift+click extends a selection;
  Shift+Left/Right/Home/End selects command text from the current caret.
- Double-click selects a word or a complete highlighted entity ID. Entity
  references in command results use the teal accent, including IDs, runtime
  handles, parents, children, and active cameras.
- Ctrl+C copies the active selection. Ctrl+X cuts selected command text; output
  stays read-only. Ctrl+V pastes into the command, replacing its selection.
  Ctrl+A selects the command or retained output, depending on which you clicked.
  Copied output preserves its original text across visual wraps and result chunks.
- Up/Down moves the highlight through visible suggestions, wrapping at either
  end without changing the command. When suggestions are hidden or unavailable,
  Up/Down browses command history and restores an unfinished draft and caret.
  Ctrl+Up/Down always browses history.
- Tab completes command names and supported arguments matching the
  case-sensitive prefix before the caret. Repeated Tab cycles matches
  alphabetically; Shift+Tab cycles backward. Completion replaces the current
  token and preserves the rest of the line, including leading whitespace.
  Editing, moving the caret, or browsing history starts a new completion cycle.
  After Up/Down navigation, either Tab or Shift+Tab accepts the highlighted
  suggestion; subsequent presses resume cycling in the corresponding direction.
- Matching suggestions appear above the input as you type, including at a blank
  argument. Tab highlights the current match and keeps it visible while cycling
  the original prefix's matches. An empty command shows suggestions after Tab.
  The list uses available console space and hides when the window is too short.
- Enter accepts the highlighted suggestion, replacing only the current token.
  Acceptance hides suggestions until you edit the command or press Tab; the next
  Enter executes the command.
- Click any visible suggestion to accept that row, whether or not it is
  highlighted. This replaces only the current token, preserves the rest of the
  command and quotes the value when needed, then hides the list. Press Enter to
  execute the accepted command.
- With the console open, left-click an object outside its panel to inspect that
  entity. The output includes its ID, name, hierarchy, and current component
  values. Amber corner brackets mark the picked object and follow it as it moves.
  Picking preserves your command draft and history.
- Scroll the mouse wheel over the console, drag the scrollbar, or use
  Page Up/Page Down to browse wrapped output. Ctrl+End returns to the latest
  output. Incoming messages preserve your reading position while scrolled up.

Enter executes a command when no suggestion list is visible. While a `step` or
`profile` command is pending, editing, scrolling, and accepting suggestions still
work; Enter can submit your draft once the pending result is ready. Interactive
input accepts visible UTF-8 text, up to 256 bytes. Multiline/control-character
and oversized pastes leave the command unchanged. Available glyphs depend on
the selected font. The output retains the newest 64 log entries.

The default Inter font is embedded, so console typography works from any
project directory. Games can borrow their own UI font with
`console.set_font(rune.developer_console(game), font)`. Refresh borrowed fonts
after asset hot reload and keep them alive through drawing; `console.set_font`
with an empty `rl.Font{}` restores Inter. Rune releases its console atlas before
closing the window. Standalone console users call `console.destroy_renderer`
before `rl.CloseWindow`.

### Picking scene objects

Object inspection uses the scene attached to the engine loop and its active
cameras. It converts window coordinates to the game canvas and ignores clicks
in letterbox bars or within the console panel. A hit through the active
`Camera3D` takes priority; otherwise, the active `Camera2D` selects the topmost
matching object by draw order. Picking also works while simulation is paused.
Clicks are ignored while a `step`, `profile`, or local inbox reply is pending.

The picked object's own supported rendered bounds are marked with amber corner
brackets and a dark backing. They update from live geometry and the active camera
each frame, independently of F3 gizmos. Clicking empty canvas space, closing the
console, replacing the attached scene, or deleting the entity clears the
selection. Disabling the entity or one of its ancestors hides the brackets while
retaining the selection; re-enabling it restores the brackets when it is visible.
A valid selection also temporarily hides when it is offscreen, has no supported
geometry, or has no valid active camera.

Use `@picked` wherever the engine commands accept an entity: `inspect`, `set`,
`enable`, `disable`, and `navmesh on`. For example:

```text
inspect @picked Transform
set @picked Transform.position.1 2
disable @picked
enable @picked
```

The alias resolves when the command runs, so it follows the current selection.
It is reserved ahead of scene IDs and is offered by argument completion only
while a valid picked entity is available; component and field suggestions follow
that entity too, including while it is disabled. `disable @picked` keeps the alias
valid so `enable @picked` can turn the object back on. These commands change its
local activation flag; a disabled ancestor still keeps it inactive. Closing the
console, an empty canvas click, scene replacement, or deletion invalidates the
alias. Using it with no valid selection reports an error and leaves the scene
unchanged. Custom
commands can use `rune.debug_picked_entity(game)` to obtain the current handle
and a validity flag; do not retain that handle across scene replacement.
An authored entity whose literal ID is `@picked` can use its numeric `@handle`.
`navmesh on @picked` resolves its filter immediately; picking another object
does not redirect an already enabled navmesh overlay.

The brackets draw at native UI resolution after the game canvas and game UI, and
before the console. This debug overlay does not change game materials, shaders,
depth state, or entity data and allocates no GPU resources. `capture` excludes
both the brackets and the console, leaving the completed game frame unchanged.

Supported 2D objects include shapes, sprite and text bounds, occupied tilemap
cells, and live particles. Textures and fonts must already be cached when their
dimensions are needed. Supported 3D objects include primitive meshes, spheres,
runtime static mesh triangles, and imported models whose static bounds were
cached by the renderer. Imported model bounds are approximate and do not follow
animated deformation. Disabled entities are excluded; colliders are not required.

Picking queries scene geometry rather than rendered pixels. Transparent texture
regions can still select an object. Terrain, volumes, shader displacement,
custom draw calls, and custom camera projections are not inspected. Mixed 2D/3D
scenes use the priority above even if custom drawing presents a different order.
The callback loop has no attached scene and does not provide object inspection.

### Cursor ownership

Both engine-owned loops temporarily use a visible, free cursor while the console
is open. After `rune.init` creates the window, set the desired gameplay mode with
`rune.set_cursor_mode(game, mode)`:
`.visible` shows a free cursor, `.hidden` hides a free cursor, and `.captured`
locks and hides it for mouse look. `rune.cursor_mode(game)` returns that desired
mode, including while the console temporarily overrides it. A mode change while
the console is open updates what will be restored when it closes.

Mapped gameplay input is captured through the opening and closing frames, and
mouse-delta axes discard the recapture warp before mouse look resumes. Raw
raylib input remains available; game systems reading it directly must respect
console focus and avoid relocking the cursor while the console owns it. Use
Rune's cursor setter to retain an exact hidden-free versus captured mode:
raylib's public cursor query reports both as hidden. An untracked hidden cursor
is assumed captured for compatibility with raw `DisableCursor` calls. Use Rune's
setter consistently because later raw changes between hidden-free and captured
modes cannot be detected from visibility alone.

`rune.begin_frame` manages console cursor ownership for custom loops too.
Advanced loops that call `console.update` directly should call
`rune.sync_console_cursor(game)` immediately before and after it, capture project
input whenever the console was or is open, and suppress the next sampled mouse
delta after restoring capture. The sync helper handles cursor ownership; using
`rune.begin_frame` also supplies this input-sampling protection. Draw the completed
frame before `console.finish_frame` and `console.draw`.

### Argument completion

Suggestions query the current scene and input mappings as the list refreshes
and when completing a token:

| Command argument | Suggestions |
| --- | --- |
| `inspect`, `enable`, `disable`, `set`: entity | Live entity IDs, `@handles` for unnamed entities, and `@picked` when available. |
| `inspect`: component | Components attached to the selected entity. |
| `entities`: component filter | Registered component names. |
| `set`: `Component.field` | Fields on the selected entity, including nested object fields and array indices after a dot, such as `Transform.position.0`. |
| `input`: action, then operation | Configured action names, then `press`, `release`, or `clear`. |
| `window`: mode | `windowed`, `borderless`, or `fullscreen`. |
| `navmesh`: mode, then entity | `on` or `off`, then entity IDs/handles with `NavMesh3D` after `on`; `@picked` when the picked entity qualifies. |

For example, type `inspect ` and press Tab to cycle entity IDs, or type
`inspect player Tr` and press Tab to complete an attached component. Names with
spaces, quotes, or backslashes are inserted as JSON-quoted tokens accepted by
these commands. File paths and arbitrary JSON values are not completed.

### Custom argument completion

Command names registered with `console.register` participate automatically.
For arguments, pass an optional `console.Completion_Proc` after the handler:

```odin
spawn_completion :: proc(dev: ^console.Console, request: console.Completion_Request,
                         candidates: ^[dynamic]string) {
    if request.argument_index == 0 {
        append(candidates, "knight", "slime")
    }
}

console.register(dev_console, "spawn", "Spawn a test entity.", spawn_command, spawn_completion)
```

`request.command` is the command name, `request.arguments` contains the decoded
arguments preceding the current token, `request.argument_index` is its zero-based
argument position, and `request.prefix` is its decoded text before the caret.
Append raw candidate values; the console filters by prefix, removes duplicates,
sorts matches, and quotes values when needed. The callback can run while the
interactive suggestion list refreshes and when completing a token. Treat it as a
read-only query of current game state; do not mutate gameplay or retain scene
entities across reloads.

The candidate array uses `context.temp_allocator`. Borrowed strings and temporary
strings are consumed during the current completion call. Do not retain the
request data or candidate array after the callback. Custom handlers can use
`word, rest := console.take_argument(arguments)` to decode the first argument
token and obtain the remaining argument text, including JSON-quoted tokens
completion inserts.

## Local console inbox

Use the local console inbox to invoke registered commands in a running game
without keyboard focus. Run these examples from the repository root.

On Windows, build the example, then launch it with an opt-in inbox:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
odin build examples/tilemap_2d -o:none -linker:msvc -collection:rune=rune -out:build/tilemap_2d.exe
Start-Process -FilePath ./build/tilemap_2d.exe -ArgumentList '--console-dir=build/console/tilemap' -WorkingDirectory (Get-Location).Path -WindowStyle Hidden
```

On Linux, use a terminal in a desktop session:

```bash
mkdir -p build
odin build examples/tilemap_2d -o:none -collection:rune=rune -out:build/tilemap_2d
./build/tilemap_2d --console-dir=build/console/tilemap
```

Use a second terminal to send commands. The helper examples below use the Windows
`.bat` entry point, which also works from Windows' built-in PowerShell. On Linux,
use the matching `.sh` entry point with the same arguments:

```bash
sh tools/console.sh --directory build/console/tilemap --command status --json
```

When a command contains a JSON string, double its literal quotes inside the
Windows quoted argument. For a text entity named `label`, in CMD:

```bat
tools\console.bat --directory build\console --command "set label TextRenderer.text ""Hello, Rune!""" --json
```

In a Linux shell, put the whole command in single quotes:

```sh
sh tools/console.sh --directory build/console --command 'set label TextRenderer.text "Hello, Rune!"' --json
```

After the game creates its inbox directory, send commands with the helper:

```powershell
# List all registered commands, including game-specific commands.
.\tools\console.bat --directory build/console/tilemap --command 'help'

# Save a frame to an automatically named PNG under build/captures/.
.\tools\console.bat --directory build/console/tilemap --command 'capture'

# Save a frame to a specific PNG path.
.\tools\console.bat --directory build/console/tilemap --command 'capture build/captures/tilemap.png'

# Clear the developer console output.
.\tools\console.bat --directory build/console/tilemap --command 'clear'
```

## AI inspection and control

Add `--json` to return one structured response with `ok`, `lines`, and `data`.
Use the data object directly instead of parsing human-readable log strings:

```powershell
$reply = .\tools\console.bat --directory build/console/tilemap --command 'status' --json | ConvertFrom-Json
$reply.data
```

Available engine commands:

| Command | Behavior |
| --- | --- |
| `status` | Scene, frame number, simulation time, fixed-step count, FPS, pause state, active 2D/3D cameras, entity count, and recent errors. |
| `pads` | Connected gamepad slots 0–3, names, axis counts, and live axis values. |
| `quit` | Request engine exit, acknowledging a remote request before shutdown. |
| `entities [component]` | Sorted entity IDs, names, parents, and component names; optionally filter by registered component. |
| `inspect <entity-id> [component]` | Current runtime component values and hierarchy. Runtime-only entities use the `@handle` returned by `entities`; handles expire on reload. |
| `enable <entity-id>` / `disable <entity-id>` | Change the entity's local activation setting without saving files. Disabled ancestors keep descendants inactive; descendants retain their own local settings. See [entity activation](entity_features.md#entity-activation). |
| `window [windowed\|borderless\|fullscreen]` | Inspect the current display or change window mode. Return mode, screen and framebuffer dimensions, DPI, high-DPI support, and resizable state. Changes do not save project settings. See [display settings](display.md#code-and-console). |
| `pause` / `resume` | Stop/start simulation updates while rendering, console polling, hot reload, and audio servicing continue. |
| `step [count]` | While paused, advance 1–600 simulation updates using the fixed timestep, one per rendered frame. Default: 1. Reply arrives after completion; the game remains paused. |
| `input <action> press\|release\|clear` | Override a mapped input action. Edges are consumed by simulation, so a press while paused reaches the next step. `release` holds the action up; `clear` restores physical input. |
| `set <entity-id> <Component.field> <JSON-value>` | Validate and replace an existing runtime field without saving files. Dotted numeric segments address arrays, e.g. `Transform.position.0`. Entire vectors can be supplied as JSON arrays. |
| `reload` | Reload the active scene from disk, discard runtime scene edits, and invoke scene-reload callbacks. Invalid scene data leaves the current World intact. |
| `logs [since-sequence]` | Return log entries with sequence/level/message, a `next_sequence` cursor, and a `truncated` flag when older entries were dropped. |
| `profile [frames]` | Measure 1–600 rendered frames (default: 120). Return mean/max/p95 milliseconds for frame duration, update, fixed update, and render submission. Frame duration includes presentation/wait; these are CPU timings, not GPU measurements. |
| `navmesh [on [entity-id]\|off]` | Show translucent baked 3D surfaces and triangle edges; blocked triangles are red. Optional stable NavMesh3D scene ID filters the display. No arguments reports `{enabled, entity}`; empty entity means all. Independent of F3. Requires an active Camera3D or custom-camera debug drawing. |
| `capture [path.png]` | Return the saved absolute path, dimensions, frame number, simulation time, fixed-step count, scene, and active cameras. Frame details are under `data.metadata`. |

Example repeatable inspection workflow:

```powershell
.\tools\console.bat --directory build/console/tilemap --command 'pause' --json
.\tools\console.bat --directory build/console/tilemap --command 'entities SpriteRenderer' --json
.\tools\console.bat --directory build/console/tilemap --command 'inspect knight Transform' --json
.\tools\console.bat --directory build/console/tilemap --command 'input move_right press' --json
.\tools\console.bat --directory build/console/tilemap --command 'step 5' --json
.\tools\console.bat --directory build/console/tilemap --command 'input move_right release' --json
.\tools\console.bat --directory build/console/tilemap --command 'step 1' --json
.\tools\console.bat --directory build/console/tilemap --command 'capture build/captures/after-step.png' --json
.\tools\console.bat --directory build/console/tilemap --command 'input move_right clear' --json
.\tools\console.bat --directory build/console/tilemap --command 'resume' --json
```

`step` and `profile` finish before another command is dispatched. Increase
`--timeout-seconds` for long runs, especially at low FPS. Scene inspection, edits,
and reload require the scene loop; callback loops support timing, pause/step,
input, logs, profiling, and captures. Keep gameplay changes in update/fixed-update
callbacks so pausing simulation does not mutate game state through draw callbacks.
Runtime edits use the same notifications and cache updates as typed setters.
Shape or scale edits rebuild the affected native physics body; animator asset,
clip, or autoplay changes reset playback. To persist an authored edit, change the
scene source JSON directly or save it through the game's level editor. Scene
documents are the source of truth; game editors own creating and saving them,
and Rune owns loading and instantiation. Scene export APIs and console commands
are outside the engine's scope; see the
[scene authoring boundary](../README.md#scene-authoring-boundary).

- Use a separate inbox directory for each running game. The inbox is disabled
  unless the game is launched with `--console-dir=<directory>`.
- `capture [path.png]` saves the completed game frame before the developer
  console and picked-object brackets. Game UI and enabled gizmos are included.
  Relative paths resolve from the game's working directory; parent directories
  are created.
- The helper waits for a reply, prints console output, and reports command
  failures. Its default timeout is 10 seconds; override with `--timeout-seconds`.
  A timeout removes unclaimed requests, but a claimed command may still finish;
  check the result before retrying commands with side effects.
- Commands run on the game thread, with inbox polling at most ten times per
  second. Send one command of at most 256 UTF-8 bytes per helper invocation.
- Prefer this helper over simulated keyboard input or adding one-off capture
  code to examples. Open the saved PNG to verify rendering when relevant.
- The same commands work in the in-game console (backtick to open) or through
  `console.execute(rune.developer_console(&game), "capture")` from Odin.
