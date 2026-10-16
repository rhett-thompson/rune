# Display settings

Rune enables raylib 6 high-DPI support before creating the window. Project
width/height are logical drawing units in windowed and borderless modes on
Windows. At 200% desktop scaling, 1280x720 uses a 2560x1440 framebuffer.
Other platforms follow their raylib/GLFW backend and desktop scaling behavior.
An explicit `high_dpi: false` opts out. This applies to game rendering as well as Clay.

```json
"window": {
  "width": 1280,
  "height": 720,
  "mode": "windowed",
  "high_dpi": true,
  "resizable": true,
  "vsync": true,
  "target_fps": 0
}
```

`mode` accepts `windowed`, `borderless`, or `fullscreen`. Borderless fills the
current monitor at its desktop resolution and retains DPI-aware coordinates.
It uses a normal undecorated window without exclusive monitor ownership or
always-on-top behavior, so Alt+Tab and other application switching remain available.
Window modes support static raylib and `-define:RAYLIB_SHARED=true` builds using
exported raylib APIs. Rune's borderless mode uses `WINDOW_UNDECORATED`; query it
with `rune.window_mode()`. Raylib's `BORDERLESS_WINDOWED_MODE` flag stays clear.
Exclusive fullscreen uses raylib's native fullscreen behavior: on Windows it
uses physical pixel drawing coordinates and reports DPI 1. Prefer borderless
for a fullscreen game with the same UI sizing as a window. Games using exclusive
fullscreen can choose their own reference resolution or UI scaling policy.

When `mode` is omitted, legacy `fullscreen: true` selects fullscreen; otherwise
the game starts windowed. An explicit `mode` takes precedence. The legacy flag
is still supported and now actually takes effect. `resizable` defaults to false
for compatibility with games that assume a fixed window size.

`vsync` defaults to false. Setting it to true requests display-synchronized
buffer swaps through raylib's `VSYNC_HINT`; it does not impose a 60 FPS cap.
The graphics driver or desktop compositor can override synchronization behavior.

`target_fps` sets an independent software frame-rate cap. It accepts integers
from 0 to 2147483647 and defaults to 0, which disables the cap. For example,
`"vsync": true, "target_fps": 0` requests synchronization with no software cap;
`"vsync": false, "target_fps": 120` caps rendering at 120 FPS. A cap alone does
not prevent tearing. With V-Sync enabled, a cap below the display refresh rate
can repeat displayed frames.

The initial window is centered and fitted to the available desktop. Windows
uses the monitor work area, accounting for taskbars and window decorations.
Linux uses the desktop's X11 work area when available, with a 32-pixel margin on
each edge for decorations. If no work area is available, and on other desktop
platforms, Rune fits to the monitor bounds with the same margin. Wayland
compositors can control window placement. Window size and requested desktop
position are retained across runtime mode switches, including maximized state;
desktop window managers may adjust the final decorated position. These settings
are not persisted across application launches.

## Code and console

Call mode setters from update or between frames, before `BeginDrawing`:

```odin
rune.set_window_mode(&game, .Borderless)
rune.set_window_mode(&game, .Fullscreen)
rune.set_window_mode(&game, .Windowed)
rune.toggle_borderless(&game)
rune.set_vsync(&game, true)
rune.set_target_fps(&game, 120)
display := rune.window_metrics()
```

Setters return success, and setting the current mode does nothing. Use the Rune
setters consistently so the engine can retain the normal window geometry.
Rune's frame loop completes asynchronous desktop operations such as restoring
a maximized window. Custom loops should call `rune.begin_frame(&game)` before
their update and draw work. These calls do not rewrite `project.json`.

`rune.set_vsync(&game, enabled: bool) -> bool` and
`rune.set_target_fps(&game, fps: i32) -> bool` also return success. Call them
during update or between frames, before drawing. They change the active window's
timing settings and leave the loaded startup settings intact. Pass 0 to
`set_target_fps` to remove the software cap; V-Sync remains independent.

The developer console and opt-in inbox expose:

```powershell
.\tools\console.bat --directory build/console/demo --command 'window' --json
.\tools\console.bat --directory build/console/demo --command 'window borderless' --json
.\tools\console.bat --directory build/console/demo --command 'window windowed' --json
```

The response contains `mode`, `screen`, `framebuffer`, `dpi`, `high_dpi`,
`resizable`, and the requested `vsync` state. The Clay example maps F11 to
borderless/windowed switching.

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
# Windows PowerShell; on Linux omit .exe and -linker:msvc, and use ./build/...
New-Item -ItemType Directory -Force build | Out-Null
$exe = '.exe'
odin build tools/resolution_validation -linker:msvc -collection:rune=rune "-out:build/resolution_validation$exe"
& "./build/resolution_validation$exe" --runtime
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
- `r3d_bridge.set_render_scale(&bridge, 0.75)` requests internal rendering at
  75% of the physical framebuffer dimensions while keeping native window/UI
  resolution. Accepted scales are 0.5–1.0; the initialized default is 1.0.
  Dimensions are rounded to pixels and applied on the next scene draw only
  when they change. Empty/minimized framebuffers retain existing targets.
  Scale has no effect while `match_framebuffer` is false. Reapply the desired
  scale when constructing a new bridge after renderer shutdown.
- 2D camera zoom remains game-owned. Resizing normally reveals more world.
  The optional `render_2d` canvas selects a fixed reference resolution; DPI alone
  does not select a policy.
- Font atlases remain asset-owned. For smooth text use a TrueType font loaded at
  the desired physical text size; DPI support cannot add detail to bitmap fonts.

Earlier runtime checks passed on Windows at 200% DPI. On 2026-10-16, static and
shared raylib window checks also passed on Windows and Ubuntu WSLg/X11 at 100%
scaling. Multi-monitor DPI moves, native Wayland, and macOS still require testing.

```powershell
# Windows PowerShell; on Linux omit .exe and -linker:msvc, and use ./build/...
New-Item -ItemType Directory -Force build | Out-Null
$exe = '.exe'
odin build tools/window_validation -linker:msvc -collection:rune=rune "-out:build/window_validation$exe"
& "./build/window_validation$exe"
& "./build/window_validation$exe" --frame-pacing-runtime
& "./build/window_validation$exe" --runtime
& "./build/window_validation$exe" --startup-windowed
& "./build/window_validation$exe" --startup-borderless
& "./build/window_validation$exe" --startup-fullscreen
```

The validation helpers also compile this validator with
`-define:RAYLIB_SHARED=true` to check shared-library linkage. To run that variant
on Windows, place the toolchain's matching `raylib.dll` beside the executable or
on `PATH`; on Linux, make its `vendor/raylib/linux` directory available through
`LD_LIBRARY_PATH` if it is not already on the loader's search path.

`--frame-pacing-runtime` hides windows after startup, checks independent V-Sync
and cap settings, measures the native software limiter, and exercises engine
reinitialization. Reported swap timing depends on the driver and compositor.
`--runtime` includes those checks plus mode transitions, restoration,
drawing/scissor pixels, and raylib mouse coordinates against Clay bounds. It
briefly opens windows and switches display modes. Verify visible frame pacing
and tearing separately on 60 Hz and high-refresh-rate displays.
