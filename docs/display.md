# Display settings

Rune enables raylib 6 high-DPI support before creating the window. Project
width/height are logical drawing units in windowed and borderless modes. At
200% desktop scaling, 1280x720 uses a 2560x1440 framebuffer. An explicit
`high_dpi: false` opts out. This applies to game rendering as well as Clay.

```json
"window": {
  "width": 1280,
  "height": 720,
  "mode": "windowed",
  "high_dpi": true,
  "resizable": true
}
```

`mode` accepts `windowed`, `borderless`, or `fullscreen`. Borderless fills the
current monitor at its desktop resolution and retains DPI-aware coordinates.
Exclusive fullscreen uses raylib's native fullscreen behavior: on Windows it
uses physical pixel drawing coordinates and reports DPI 1. Prefer borderless
for a fullscreen game with the same UI sizing as a window. Games using exclusive
fullscreen can choose their own reference resolution or UI scaling policy.

When `mode` is omitted, legacy `fullscreen: true` selects fullscreen; otherwise
the game starts windowed. An explicit `mode` takes precedence. The legacy flag
is still supported and now actually takes effect. `resizable` defaults to false
for compatibility with games that assume a fixed window size.

The initial window is centered and fitted to the available desktop. Windows
uses the monitor work area, accounting for taskbars and window decorations.
Other desktop platforms query the bundled GLFW backend's work area. Window size and
position are retained across runtime mode switches, including maximized state;
they are not persisted across application launches.

## Code and console

Call mode setters from update or between frames, before `BeginDrawing`:

```odin
rune.set_window_mode(&game, .Borderless)
rune.set_window_mode(&game, .Fullscreen)
rune.set_window_mode(&game, .Windowed)
rune.toggle_borderless(&game)
display := rune.window_metrics()
```

Setters return success, and setting the current mode does nothing. Use the Rune
setters consistently so the engine can retain the normal window geometry.
These calls do not rewrite `project.json`.

The developer console and opt-in inbox expose:

```powershell
./tools/console.ps1 -Directory build/console/demo -Command 'window' -Json
./tools/console.ps1 -Directory build/console/demo -Command 'window borderless' -Json
./tools/console.ps1 -Directory build/console/demo -Command 'window windowed' -Json
```

The response contains `mode`, `screen`, `framebuffer`, `dpi`, `high_dpi`, and
`resizable`. The Clay example maps F11 to borderless/windowed switching.

## Drawing coordinates and resolution

2D projects can opt into a reference canvas in `project.json`:

```json
"render_2d": { "policy": "fit", "width": 960, "height": 550 }
```

| Policy | Behavior |
| --- | --- |
| `native` (default) | Draw directly at the window's logical size. |
| `fit` | Preserve the reference aspect ratio with black letterbox bars. |
| `stretch` | Fill the window, allowing different horizontal/vertical scales. |
| `integer` | Fit at whole physical-pixel multiples using nearest-neighbor filtering. Below 1x, fit fractionally so the whole canvas stays visible. |

Fit/stretch use bilinear filtering. Reference dimensions must be 1–8192.
The reference render texture is reused until dimensions change, and the output
rectangle follows window/DPI changes. Integer scaling uses physical pixels,
including on displays with fractional desktop scaling.

`rune.set_resolution_2d(&game, {policy=.integer,width=320,height=180})` changes
policy at runtime. Call it during update. Use `rune.canvas_size(&game)` in
gameplay layout calculations and `rune.mouse_canvas_position(&game)` for mouse
input; its second return value is false in the letterbox bars. Pass the returned
canvas point to `GetScreenToWorld2D` for world picking. Do not use raw mouse
coordinates to pick objects in a scaled canvas.

In a scene loop, `pre_draw`, scene rendering, `draw`, and gizmos render into the
canvas. `System.draw_ui` runs after presentation at native logical UI resolution,
as does the developer console. Keep Clay's native-size layout/drawing in
`ui_update`/`draw_ui` when using a reference canvas. Existing `draw` callbacks
continue to render with the game; callback loops also wrap their draw callback
in the canvas. Camera-follow bounds and tilemap culling use its dimensions.
The policies are intended for 2D projects; 3D projects should normally use native
output and the bridge's internal-resolution controls.

The particle example keeps its effects and labels in a 960x550 reference canvas.
Set `render_2d.policy` in its `project.json` before launching to try another
policy. The runtime validator below checks fit, stretch, and integer scaling.

```powershell
odin build tools/resolution_validation -collection:rune=rune -out:build/resolution_validation.exe
./build/resolution_validation.exe --runtime
```

- Use `GetScreenWidth/Height` for screen-space drawing, Clay layout, camera
  offsets, and pointer hit-testing. raylib already transforms mouse positions
  and drawing coordinates for DPI. Do not multiply them by DPI again.
- Rune's 2D renderer and gizmos preserve that screen transform when entering
  camera mode. For custom 2D camera drawing, use
  `render.begin_camera_2d(camera)` from `rune:render`, paired with
  `rl.EndMode2D()`. raylib 6's raw `BeginMode2D` drops the screen DPI transform.
  Call the helper from screen space; it also preserves unscaled render-texture
  coordinates when used inside `BeginTextureMode`.
- Use `GetRenderWidth/Height` when allocating a render target that should match
  the physical framebuffer. Refresh it on size changes, not every frame.
- Rune's r3d bridge follows the framebuffer size by default, updating internal
  render targets only when dimensions change. Set `bridge.match_framebuffer =
  false` after initialization to retain a custom internal rendering resolution.
  Camera field of view remains unchanged.
- 2D camera zoom remains game-owned. Resizing normally reveals more world.
  The optional `render_2d` canvas selects a fixed reference resolution; DPI alone
  does not select a policy.
- Font atlases remain asset-owned. For smooth text use a TrueType font loaded at
  the desired physical text size; DPI support cannot add detail to bitmap fonts.

Runtime checks are validated on Windows at 200% DPI. Multi-monitor DPI moves,
macOS, and Linux require testing on those configurations.

```powershell
odin build tools/window_validation -collection:rune=rune -out:build/window_validation.exe
./build/window_validation.exe
./build/window_validation.exe --runtime
./build/window_validation.exe --startup-windowed
./build/window_validation.exe --startup-borderless
./build/window_validation.exe --startup-fullscreen
```

The runtime check exercises mode transitions, restoration, drawing/scissor
pixels, and raylib mouse coordinates against Clay bounds. It briefly opens a
window and switches display modes.
