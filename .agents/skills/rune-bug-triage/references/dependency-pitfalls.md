# Rune dependency pitfalls

These observations were verified on 2026-10-16 against Rune through `861a3d4`.
Recheck the current pin and implementation before applying them. Paths are
relative to the Rune checkout; existing source and maintained docs take priority
over this historical baseline.

## High DPI and Camera2D

Relevant files: `rune/render/camera.odin`, `rune/render/render.odin`,
`rune/gizmos/gizmos.odin`, `docs/display.md`,
`tools/particle_validation/main.odin`.

- Raw raylib 6 `BeginMode2D` resets the modelview and applies only the camera
  matrix, losing `BeginDrawing`'s screen scale. `EndMode2D` restores that scale
  on the default framebuffer. This can split world drawing from logical overlays
  and mouse coordinates at non-unit DPI.
- Rune already provides `render.begin_camera_2d(camera)`: save the current
  screen modelview, enter raylib camera mode, then compose `screen * camera`.
  The built-in renderer and 2D gizmos use it. Custom drawing should call the
  helper from screen space, outside another camera mode, and pair it with
  `rl.EndMode2D()`.
- A render texture begins with an identity modelview and texture-pixel
  projection. The helper preserves those units. Unconditionally adding monitor
  DPI to every camera path would break offscreen rendering.
- Use `GetScreenWidth/Height` and logical mouse positions for screen-space
  layout/picking; use `GetRenderWidth/Height` for physical framebuffer targets.
  Do not multiply already logical mouse coordinates by DPI without examining
  the conversion being performed.
- The claimed 5.5-to-6.0 move of screen scaling from `BeginMode2D` to `EndMode2D`
  was false: [5.5](https://github.com/raysan5/raylib/blob/5.5/src/rcore.c#L1003-L1021)
  already used the same begin/end logic as
  [6.0](https://github.com/raysan5/raylib/blob/6.0/src/rcore.c#L942-L960).

Verification: record actual screen size, framebuffer size, DPI, and backend.
`WINDOW_HIGHDPI` alone does not establish a non-unit scale. At 125% Linux/X11,
raw camera drawing and picking failed while Rune's helper passed; Rune's
particle/gizmo and offscreen runtime checks passed too. The existing particle
validator requires `--runtime` and can also pass at 100%, so check the measured
condition. Compare visible pixels and inverse camera picking with a translated,
rotated, zoomed camera. The world-coordinate error is not generally just
`world / scale` when the camera has an offset or target.

The recorded fractional run used Ubuntu 24.04 under WSL2, an isolated Xvfb/X11
display with `Xft.dpi: 120`, and Mesa llvmpipe software rendering. The focused
probe measured screen `640x480`, framebuffer `800x600`, and DPI `1.25` on both
axes. This does not establish native Wayland or physical desktop GPU coverage.
On a display already configured for the scale being tested, the maintained
particle/gizmo/offscreen checks can be built and run from the checkout with:

```sh
mkdir -p build
sh tools/odin.sh build tools/particle_validation -collection:rune=rune \
    -collection:r3d=third_party/r3d-odin -out:build/particle_validation
./build/particle_validation --runtime
```

This validator does not by itself distinguish raw raylib from Rune or exercise
mouse picking; add the focused comparison when those are the reported symptoms.

## Shared raylib and window modes

Relevant files: `rune/core/window*.odin`, `rune/core/core.odin`,
`tools/window_validation/main.odin`, `tools/validate.sh`, `tools/validate.bat`,
`docs/display.md`.

- The pinned static raylib exposed GLFW symbols that its shared library hid.
  A static build passing does not establish shared-library compatibility.
  Inspect the actual vendor `RAYLIB_SHARED` default rather than assuming it.
- Rune window handling uses exported raylib APIs and bounded platform-specific
  Win32/X11 queries. Avoid direct calls into raylib's private GLFW instance or
  linking another GLFW copy to operate on its state. Treat native handles
  according to the backend's documented type.
- `rune.shutdown` restores a visible, unlocked cursor through raylib before
  hiding or destroying its window, and resets the tracked cursor state directly
  so console ownership cannot restore capture during teardown. Keep normal
  shutdown in the cleanup path when investigating pointer reports; forced
  process termination does not run it. Check `rune/core/cursor.odin` and the
  shutdown ordering in `rune/core/core.odin`. Do not compensate with system
  pointer settings or Win32 `ShowCursor` counter loops.
  Run `./build/window_validation.exe --cursor-shutdown-runtime` after building
  the validator; `--runtime` includes it too. All seven native Windows/GLFW
  cases passed on 2026-10-25, covering windowed visible/hidden/captured/raw
  capture/console ownership and borderless/fullscreen capture. The fixture waits
  up to 30 seconds for actual foreground ownership, which Windows can deny.
  A transparent remote-desktop cursor may retain `CURSOR_SHOWING`, so the test
  also checks its handle changed. Initial confinement is asserted only in
  windowed capture cases; borderless/fullscreen bounds may already equal the
  desktop. All modes must restore the original desktop bounds on shutdown.
  Post-destruction cursor assertions observe global desktop state after the
  test window relinquishes ownership. If they fail, inspect the native query's
  return value, flags, handle, clip bounds, and foreground owner separately;
  failure in the visible baseline alone does not establish a capture-release bug.
- Window-mode fixes must retain ordinary borderless behavior, fullscreen,
  restored geometry/maximization, DPI, and frame pacing. Native resize and window
  decoration callbacks can lag a request; cached dimensions may be stale.
- Custom engine loops should call `rune.begin_frame`, which processes pending
  window state. Follow the current display docs instead of copying old GLFW
  workarounds.
- Startup creates a hidden native window through initial sizing and mode setup.
  `rune.init(path, defer_window_show = true)` and
  `rune.init_project(defer_window_show = true)` keep it hidden through game asset
  and preference loading; false remains the default and reveals before return
  unless project `window.hidden` is true.
  Built-in scene/callback loops reveal after the first completed `EndDrawing`;
  custom loops call `rune.show_window(&game)` after their first full
  `EndDrawing`. Its later calls do nothing, preserving an intentionally hidden
  window. It also respects persistent hiding. Win32 exclusive fullscreen forces
  visibility, so that startup mode is queued until reveal while windowed/borderless
  changes apply during deferred startup. Use
  `rune.window_mode(&game)` for the queued request and the no-argument query for
  native state. `tools/window_validation --deferred-startup-runtime` covers the
  lifecycle; inspect visible startup separately on the affected desktop.
- Project `window.hidden: true` keeps both engine-owned loops hidden.
  `rune.set_window_hidden` and `window hidden` / `window show` change runtime
  visibility. Mode changes while persistently hidden are queued. Hiding an
  exclusive-fullscreen window leaves native fullscreen and retains the requested
  mode for reveal: GLFW ignores a direct fullscreen hide, even though raylib sets
  its cached hidden flag. Inspect native visibility in addition to `hidden`, and
  distinguish `window_metrics(&game).mode` from its `requested_mode`.
- In the pinned raylib 6 backend, `RestoreWindow` acts only on resizable windows.
  Rune's explicit show temporarily enables resizing for restoration and then
  restores the original setting; see `rune/core/window.odin`. On 2026-10-25,
  combined hidden/deferred-startup checks passed with static and shared raylib
  on Windows/GLFW at 100% scaling (NVIDIA RTX 5070, OpenGL 3.3, pinned October
  Odin/MSVC). They checked both cached `IsWindowMinimized` and native `IsIconic`
  after explicit show, retained resizable/always-run settings, and native-hidden
  startup of the next engine. This does not establish minimized restoration on
  other desktop backends.
- Closing while still minimized, including while hidden, retains raylib's
  minimized flag across `CloseWindow`. A subsequent engine in the same process
  can replay minimization and expose the startup surface. This remains a pinned
  backend limitation: a native restore can map/focus the window, so shutdown
  does not attempt it solely to clear retained state. Prefer hidden automation
  over minimization, or explicitly `window show` before shutdown/reinitialization
  to restore a minimized window. Separate process-per-run launches do not
  inherit this state. Check `rune/core/core.odin`, `rune/core/window.odin`, and
  `tools/window_validation/main.odin` when changing this lifecycle.
- Console capture reads the drawn framebuffer before presentation and rejects
  hidden windows at command acceptance and execution with
  `data.error: "capture_window_hidden"`. Failures must finish transport/batch
  replies and leave no PNG. A visible flag does not guarantee settled buffers:
  `tools/window_validation/main.odin` allows multiple frames for readback after
  mode changes. Do not infer a compositor or driver failure from a deliberate
  hidden-capture rejection, or promise capture readiness after exactly one frame.
- Hidden does not mean headless or physically input-isolated. The graphics
  context still needs a display backend, and Rune continues gamepad sampling.
  Hidden/occluded swap pacing may differ; fixed paused simulation delta does not
  make frame callbacks or wall-time-driven game logic deterministic.

Use the shared window validator link check and relevant runtime transitions.
Distinguish WSLg/X11 software-rendering coverage from native Wayland, desktop
GPU drivers, or other untested backends.

## Clay dropdown clipping and native archives

Relevant files: `rune/ui/dropdown.odin`, `rune/ui/dropdown_test.odin`,
`rune/ui/render.odin`, `third_party/clay/README.rune.md`,
`third_party/clay/clay.h`, `third_party/clay/clay-odin/clay.odin`.

- The floating dropdown intentionally escapes the enclosing menu's scroll clip
  and uses its own viewport. Options visible outside the ancestor clip should
  remain clickable. The nested dropdown test asserts this behavior; its failure
  messages do not mean that inheriting the menu clip is desirable.
- The upstream Linux archive contained two `clay.o` members. The linker selected
  an older implementation that ignored `clipTo = None`, even though the committed
  header and binding supported it. Rebuilding from that header corrected both
  rendering and pointer hits. Rune now ships the rebuilt archive.
- Compare the platform artifact actually selected by the binding, its ABI,
  archive membership (`ar t`), and symbol index/definitions (`nm`). If needed,
  inspect the implementation selected in the linked executable.
- The pinned upstream header allocates only ten persistent scroll-container
  entries. Every clip, including a single-line text input, uses one. Rune's
  header patch bounds this storage by `maxElementCount`; `Clay_MinMemorySize`
  includes it through the same initializer. A header-only edit does not update
  an already linked native artifact. Rebuild the relevant artifact from the
  patched header, then run the many-field inspector regression in
  `rune/ui/scroll_nested_test.odin` and the serial UI suite. The patched Windows
  object built with MSVC 19.51 passed all 30 serial headless UI tests on
  2026-10-18 before publication. The Linux AMD64 archive built with Zig 0.15.2 /
  Clang 20.1.2 and GNU ar 2.42 passed all 30 serial UI tests in Ubuntu WSL against
  both the staged and published copies with pinned Odin
  `dev-2026-10-nightly:84bc3fc` on the same date. See the native artifact notes
  for exact compilation flags, runtime limits, and remaining platforms.
- Build a fresh archive in a unique scratch directory; updating a malformed
  archive in place can preserve duplicate members. Follow the staged
  build/test/publish recipe in `third_party/clay/README.rune.md`. Keep the
  header, binding, and native implementation consistent.

Run the UI suite serially on the affected platform. A correctly applied
`ODIN_TEST_NAMES=ui.test_name` filter should select one test; a trailing comma
does not imply that all tests should run. Check the runner output before calling
a run isolated or attributing a failure to concurrency.

## Audio device availability and ownership

Relevant files: `rune/audio/audio.odin`, `rune/audio/preload.odin`,
`tools/mixer_validation/main.odin`, `tools/audio_stop_validation/`,
`docs/audio-mixer.md`.

- Repeated raw `InitAudioDevice` calls can trigger native backend failures.
  Rune checks `IsAudioDeviceReady()` before initializing and records
  `owns_device` only when Rune opened a device successfully.
- Shutdown releases Rune-owned sounds, aliases, and streams before closing the
  device, and closes it only when Rune owns it. An externally initialized device
  must remain open. Borrowers must be destroyed before the owner: this ownership
  flag is not reference counting.
- Check both already-initialized/external ownership and Rune-owned lifecycle
  cases. `available` or `IsAudioDeviceReady()` does not prove audible playback.
  A PulseAudio assertion alone does not prove a permanent daemon failure or
  justify changing stop/playback semantics.

Use the mixer ownership regression and audio runtime validators as appropriate;
record whether an actual playback backend was available.

## R3D preparation and apparently dirty submodules

Relevant files: `third_party/r3d-compat/README.md`,
`third_party/r3d-compat/bindings.patch`, `third_party/r3d-compat/files.blobs`,
`tools/prepare_r3d.sh`, `tools/prepare_r3d.bat`.

Rune keeps the official upstream submodule pin and applies a parent-owned
compatibility patch locally. That expected submodule diff is reproducible from
already tracked Rune files. Inspect its provenance before resetting it or
creating a submodule commit and changing the gitlink.

The preparation helper validates the exact pin and canonical tracked diff,
rejecting unrelated tracked or untracked changes. `--check` accepts pristine or
already prepared input without applying the patch; passing it alone does not
make pristine input ready for manual builds. Run actual preparation when needed.
