# Runtime console commands

## In-game console

Press backtick to open the console and Escape or backtick to close it. The
overlay uses Inter typography, rounded navy panels, and the game UI's teal
accent. Warning and error messages have distinct colors.

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
- Up/Down browses command history and restores an unfinished draft and caret.
- Scroll the mouse wheel over the console, drag the scrollbar, or use
  Page Up/Page Down to browse wrapped output. Ctrl+End returns to the latest
  output. Incoming messages preserve your reading position while scrolled up.

Enter executes a command. While a `step` or `profile` command is pending,
editing and scrolling still work; Enter leaves your draft intact until the
pending result is ready. Interactive input accepts visible UTF-8 text, up to 256
bytes. Multiline/control-character and oversized pastes leave the command
unchanged. Available glyphs depend on the selected font. The output retains the
newest 64 log entries.

The default Inter font is embedded, so console typography works from any
project directory. Games can borrow their own UI font with
`console.set_font(rune.developer_console(game), font)`. Refresh borrowed fonts
after asset hot reload and keep them alive through drawing; `console.set_font`
with an empty `rl.Font{}` restores Inter. Rune releases its console atlas before
closing the window. Standalone console users call `console.destroy_renderer`
before `rl.CloseWindow`.

## Local console inbox

Use the local console inbox to invoke registered commands in a running game
without keyboard focus. Run these examples from the repository root.

On Windows, build the example, then launch it with an opt-in inbox:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
odin build examples/tilemap_2d -linker:msvc -collection:rune=rune -out:build/tilemap_2d.exe
Start-Process -FilePath ./build/tilemap_2d.exe -ArgumentList '--console-dir=build/console/tilemap' -WorkingDirectory (Get-Location).Path -WindowStyle Hidden
```

On Linux, use a terminal in a desktop session:

```bash
mkdir -p build
odin build examples/tilemap_2d -collection:rune=rune -out:build/tilemap_2d
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
clip, or autoplay changes reset playback. To persist an
edit, change the source JSON explicitly; no command automatically saves a scene.

- Use a separate inbox directory for each running game. The inbox is disabled
  unless the game is launched with `--console-dir=<directory>`.
- `capture [path.png]` saves the completed game frame before the developer
  console overlay. Game UI and enabled gizmos are included. Relative paths
  resolve from the game's working directory; parent directories are created.
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
