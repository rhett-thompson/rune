# Runtime console commands

Use the local console inbox to invoke registered commands in a running game
without keyboard focus. Run these examples from the repository root.

Build the example, then launch it with an opt-in inbox:

```powershell
odin build examples/tilemap_2d -collection:rune=rune -out:build/tilemap_2d.exe
Start-Process -FilePath ./build/tilemap_2d.exe -ArgumentList '--console-dir=build/console/tilemap' -WorkingDirectory (Get-Location).Path -WindowStyle Hidden
```

After the game creates its inbox directory, send commands with the helper:

```powershell
# List all registered commands, including game-specific commands.
./tools/console.ps1 -Directory build/console/tilemap -Command 'help'

# Save a frame to an automatically named PNG under build/captures/.
./tools/console.ps1 -Directory build/console/tilemap -Command 'capture'

# Save a frame to a specific PNG path.
./tools/console.ps1 -Directory build/console/tilemap -Command 'capture build/captures/tilemap.png'

# Clear the developer console output.
./tools/console.ps1 -Directory build/console/tilemap -Command 'clear'
```

## AI inspection and control

Add `-Json` to return one structured response with `ok`, `lines`, and `data`.
Use the data object directly instead of parsing human-readable log strings:

```powershell
$reply = ./tools/console.ps1 -Directory build/console/tilemap -Command 'status' -Json | ConvertFrom-Json
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
| `capture [path.png]` | Return the saved absolute path, dimensions, frame number, simulation time, fixed-step count, scene, and active cameras. Frame details are under `data.metadata`. |

Example repeatable inspection workflow:

```powershell
./tools/console.ps1 -Directory build/console/tilemap -Command 'pause' -Json
./tools/console.ps1 -Directory build/console/tilemap -Command 'entities SpriteRenderer' -Json
./tools/console.ps1 -Directory build/console/tilemap -Command 'inspect knight Transform' -Json
./tools/console.ps1 -Directory build/console/tilemap -Command 'input move_right press' -Json
./tools/console.ps1 -Directory build/console/tilemap -Command 'step 5' -Json
./tools/console.ps1 -Directory build/console/tilemap -Command 'input move_right release' -Json
./tools/console.ps1 -Directory build/console/tilemap -Command 'step 1' -Json
./tools/console.ps1 -Directory build/console/tilemap -Command 'capture build/captures/after-step.png' -Json
./tools/console.ps1 -Directory build/console/tilemap -Command 'input move_right clear' -Json
./tools/console.ps1 -Directory build/console/tilemap -Command 'resume' -Json
```

`step` and `profile` finish before another command is dispatched. Increase
`-TimeoutSeconds` for long runs, especially at low FPS. Scene inspection, edits,
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
  failures. Its default timeout is 10 seconds; override with `-TimeoutSeconds`.
  A timeout removes unclaimed requests, but a claimed command may still finish;
  check the result before retrying commands with side effects.
- Commands run on the game thread, with inbox polling at most ten times per
  second. Send one command of at most 256 UTF-8 bytes per helper invocation.
- Prefer this helper over simulated keyboard input or adding one-off capture
  code to examples. Open the saved PNG to verify rendering when relevant.
- The same commands work in the in-game console (backtick to open) or through
  `console.execute(rune.developer_console(&game), "capture")` from Odin.
