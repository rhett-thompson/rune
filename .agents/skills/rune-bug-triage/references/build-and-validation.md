# Rune builds, validation, and tested artifacts

Paths are relative to the Rune checkout. Check the current `toolchain.json`,
`README.md`, validation helpers, and relevant source before relying on this
guidance; the baseline below was inspected on 2026-10-16 at `861a3d4`.

## Windows linker requirements

With the recorded Odin October toolchain, manual Windows build/run/test commands
need `-linker:msvc`. The default RAD linker cannot link the bundled zlib MSVC
`/GL` objects used by r3d, and has crashed on Clay/window validators. Linux uses
its platform linker default; omit the MSVC flag there. See `README.md`, Setup.

`tools/odin.ps1` and `tools/odin.bat` serialize compilation and forward arguments;
they do not supply this flag. For example, from Rune's root in PowerShell:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
./tools/odin.ps1 -OdinArguments @(
    'test', 'rune/ui', '-collection:rune=rune', '-linker:msvc',
    '-define:ODIN_TEST_THREADS=1', '-out:build/ui_test.exe'
)
```

Rune's Windows launcher and build/validation helpers select MSVC themselves.
Published Windows players additionally select `-subsystem:windows`. If a
published game opens a console, inspect its PE optional-header Subsystem:
2 is Windows GUI, 3 is Windows CUI. The publisher's compiler arguments and
native audit enforce GUI in `rune_publish/process.odin` and `native.odin`;
changing runtime window visibility does not change the executable subsystem.
Existing generated games retain copied build helpers: inspect that game's
`build.bat` when an engine/toolchain upgrade exposes an old linker choice.

## Choose checks that exercise the symptom

Build the relevant tool with the compiler wrapper, using
`-collection:rune=rune` and `-collection:r3d=third_party/r3d-odin` when needed.
Supply `-linker:msvc` on Windows. Launch the resulting executable after the build
finishes and releases the compiler lock; Windows outputs use `.exe`.

| Report concerns | Headless/configuration checks | Additional runtime checks |
| --- | --- | --- |
| Dropdown/UI layout or input | Serial `rune/ui` tests; `tools/ui_validation` | `ui_validation --runtime` for rendered pixels, clipping, and MSAA |
| Camera2D, particles, or DPI alignment | `tools/particle_validation` for simulation/configuration | `particle_validation --runtime` for camera/UI/gizmo and offscreen pixels; verify actual non-unit DPI and add picking checks when relevant |
| 2D canvas scaling or mouse mapping | `tools/resolution_validation` for layout/mapping math | `resolution_validation --runtime` for framebuffer pixels |
| Window modes, visibility, or shared-raylib linking | `tools/window_validation` for settings; compile a separate shared target with `-define:RAYLIB_SHARED=true` | `window_validation --runtime`; run `--startup-windowed`, `--startup-borderless`, and `--startup-fullscreen` in separate processes when startup modes matter; use `--hidden-runtime` for persistent visibility |
| Audio ownership, mixing, stopping, or preload | `tools/mixer_validation` and `tools/audio_stop_validation` for configuration | Both validators with `--runtime`, using a working playback backend |
| Navmesh bake coverage or path detours | `rune/navigation` tests, `tools/navigation_bake_validation`, and headless `tools/navigation_3d_validation`; compare actual route lengths on the reported bake/query settings | `navigation_3d_validation --runtime` when visible agent motion or rendered navigation is the symptom |
| Terrain editing or reload retention | `tools/terrain_validation` for PNG/R16 decoding, CPU data ownership, native collision, corrupt-heightmap retention and recovery | `terrain_validation --runtime` for GPU chunk replacement, invalid-reload retention, materials and instanced details |
| Console transport, batching, or completion | `rune/console` tests, focused `rune/core` console/quit tests, and `tools/console_validation` | `debug_console_validation --runtime` for capture pixels, profile completion, and results retained across rendered frames |
| Paused stepping, fast-step input, or frame pacing | `rune/core/fast_step_test.odin` and `rune/input/fast_step_test.odin` within their package tests | `fast_step_validation --runtime` for actual callback/scene tick cadence, deferred ordering, runtime cap restoration, and interrupted commands |

The table names tool packages; runtime commands refer to the executables built
from them. UI pixel checks do not replace the serial dropdown/input tests.
Camera runtime checks can pass at 100% DPI, which does not exercise scale loss.
Audio runtime validators intentionally mute playback, so passing them does not
establish audible output.

On 2026-10-23, both terrain validator modes passed with the pinned October Odin
compiler and MSVC linker on Windows AMD64; hidden-window rendering used an
NVIDIA GTX 1060 and OpenGL 3.3. Invalid edits retained native collision and GPU
chunks, and valid repairs replaced them. This does not establish Linux behavior.

Inspect stdout/stderr for skipped branches as well as the exit status.
For example, window runtime can report a skipped maximized roundtrip when the
desktop backend did not maximize. Report that case as untested. Without
`--runtime`, an audio stop validation pass covers configuration, not playback.

For wider validation, use `tools/validate.bat --all-examples` on Windows or
`sh tools/validate.sh --all-examples` on Linux. Add `--runtime` for the optional
graphics/audio checks, with their prerequisites available. The aggregate helpers
compile `window_validation_shared` but do not run it; they also do not invoke the
three window startup flags. Run those separately when relevant, and make the
matching shared raylib available to the loader as described in `docs/display.md`.

Use `tools/release_check.bat` or `sh tools/release_check.sh` for isolated exports
and generated-project/build-helper regressions. They already include aggregate
validation; normally choose a release check or a full validation run instead of
duplicating both. See `docs/release.md` and `docs/linux.md` for current commands,
runtime logs, timeouts, and platform limits. Choose focused checks for a focused
fix; do not require the full release workflow for every report.

## Console transport validation

Use the serial `rune/console` tests for batch parsing, bounds, ordering, failure
continuation, result ownership, and the single-command inbox. The focused tests
in `rune/core/console_batch_test.odin` and the quit tests in
`rune/core/gamepad_exit_test.odin` exercise actual engine commands, deferred
stepping, partial replies, and loop exit. Use the compiler wrapper and the
`rune`/`r3d` collections described above. `tools/console_validation` also runs
headless inbox checks. Build `tools/debug_console_validation`, then run its
executable with `--runtime` to check capture pixels, profile completion after
presentation, and retained batch results across frame-arena resets. Both
aggregate helpers include this validator when `--runtime` is selected; it
requires a display.

Persistent visibility checks use `tools/window_validation --hidden-runtime`.
Cover both engine-owned loops, configured hidden startup, repeated hide/show,
mode changes while hidden, fullscreen restoration, minimized-to-hidden behavior,
and engine reinitialization. Check native visibility where supported rather than
trusting raylib's cached hidden flag. Successful console captures now require a
non-hidden window; the debug-console validator also checks named hidden-capture
errors and continuation after failed captures. Historical hidden-readback results
below predate this conservative capture contract and do not override it.

On 2026-10-25, the debug-console runtime validator passed hidden-capture checks
on Windows AMD64 with static raylib 6, GLFW/Win32, OpenGL 3.3, and an NVIDIA
RTX 5070 at 100% scaling. It rejected both a command issued while hidden and a
queued capture hidden before readback, created no output directory or PNG,
cleared the pending request, and completed a batch containing a failed capture
followed by successful inspection. Successful capture cases revealed the window.
These checks do not establish other backends or cross-platform settling time
after a mode transition.

The same 2026-10-25 Windows setup, pinned Odin `dev-2026-10-nightly:84bc3fc`, and
MSVC linker passed combined `window_validation --hidden-runtime
--deferred-startup-runtime` runs in one process with both static and shared
raylib. Six 65-frame hidden cases covered both engine-owned loops and all
startup modes, native `IsWindowVisible` checks, repeated hide/show, queued modes,
and reinitialization. Actual minimized-to-hidden/show checks confirmed cached
`IsWindowMinimized` and native `IsIconic` cleared after show, resizable and
`WINDOW_ALWAYS_RUN` settings were preserved, and the next engine initialized
hidden. The existing full window regression suite passed before the final
minimized-restoration adjustment; final combined runs covered visibility and
lifecycle. All 33 fast-step runtime cases and the debug-console visibility-command
batch also passed during this change. These results cover native Windows;
other desktop backends require separate validation.

On 2026-10-25, Ubuntu 24.04.2 WSL2 with pinned Odin
`dev-2026-10-nightly:84bc3fc` passed static/shared window configuration and
combined hidden/deferred-startup checks under isolated Xvfb, GLFW/X11, Mesa
25.2.8 llvmpipe (LLVM 20.1.2), and OpenGL 4.5. Both builds exercised six 65-frame
callback/scene-loop and startup-mode cases plus reinitialization. Debug-console
visibility payloads, hidden-capture rejection, successful captures, batch
continuation, and all 33 fast-step runtime cases passed too. There was no window
manager, so minimization checks were skipped; native visibility assertions are
Windows-only. The Linux binaries preceded the final direct-minimized-show fast
path adjustment, which these runs did not exercise. These results establish the
tested X11 paths, not minimized restoration, native Wayland, hardware GPU
behavior, or case sensitivity on a native Linux filesystem.

For `step --fast`, also run the focused `fast_step_*` core tests and
`clear_transients_*` input tests. They cover argument validation and completion,
counts around the eight-tick boundary, controlled component-state comparisons,
cached physical versus injected input edges, batch sequencing, and interrupted
completion. Build `tools/fast_step_validation` with the same compiler wrapper and
collections, then run the resulting executable with `--runtime`. It creates a
hidden window and exercises both engine-owned loops. The aggregate helpers
include it with `--runtime`; without that flag the executable does not exercise
the loops. A display backend is required even when the window is hidden.

When diagnosing cap restoration, distinguish `engine.window.target_fps` (the
desired runtime cap) from the native software cap temporarily removed during a
fast step. Check actual presented-frame timing as well as the retained value,
including a `set_target_fps` call made during the command. The project value is
the startup setting, and averaged FPS can include frames from before restoration.
V-Sync remains independent. Compare controlled simulation/component values;
fast stepping changes frame-service cadence and does not promise identical
frame counts, FPS, live input, or wall-time behavior.

Engine loops call `stop_debug_console` before teardown to restore temporary
pacing and publish interrupted command/batch results. Custom loops using engine
debug commands must do the same. `console.stop_remote` handles only transport
cleanup and cannot restore an engine frame-cap override. See
`rune/core/debug_commands.odin`, `rune/core/core.odin`, and
`docs/runtime-console.md` (Custom console loops and result ownership).

Sender fixtures are optional and use only Python 3's standard library:

```text
python tools/console_sender_validation.py --help
python tools/console_sender_validation.py --sender windows
python tools/console_sender_validation.py --sender sh --shell /path/to/sh
```

The `windows` mode requires Windows Script Host; `--shell` selects a POSIX shell,
including Git for Windows. These fixtures inspect published request bytes and
provide replies to test parsing, failures, and timeout cleanup. They do not run
the engine, and Python is not required by the aggregate validation helpers.

On 2026-10-24, the pinned October Odin compiler with MSVC passed the headless
console/core checks on Windows AMD64. Hidden-window batch capture/profile checks
passed with GLFW and OpenGL 3.3 on an NVIDIA RTX 5070. Python 3.10 sender fixtures
passed against the Windows JScript sender and Git for Windows `sh`; the Windows
fixtures invoke the JScript body with the batch wrapper's argument environment.
The shell fixtures also passed on Ubuntu under WSL with Python 3.12 and GNU Awk
5.2.1 using the Windows-mounted checkout.

Linux engine checks on 2026-10-24 used Ubuntu 24.04.2 WSL2, glibc 2.39, the same
pinned compiler, and static raylib, at `8bcea68` plus the working-tree batch
implementation. All 84 console tests and six focused core tests passed, as did
the headless inbox validator and rendered capture/profile checks. Rendering used
isolated Xvfb, GLFW/X11, and Mesa 25.2.8 llvmpipe. Additional actual callback and
scene-loop checks exercised deferred step/profile completion, mid-batch quit,
and `request_exit` between entries or during `step 600`/`profile 600`; scene
shutdown callbacks observed the finalized reply before teardown. The Linux
sender also passed against the freshly built Hello World scene engine with
`pause`, `step 60`, `profile 3`, `status`, and `quit`, plus an incomplete quit
prefix. See `rune/core/core.odin` for the loop cleanup ordering.

Fast-step validation on 2026-10-24 used the same pinned compiler and static
raylib, at `8bcea68` plus the batch and fast-step working-tree changes. All 35
core, 20 input, and 84 console tests passed serially on Windows and Ubuntu WSL2;
the rendered debug-console and player-profile validators passed on both too.
`fast_step_validation --runtime` passed 33 real-loop cases on each platform,
covering both loops, 1/7/8/9/600 ticks, injected edges, capture/profile ordering,
interruption, V-Sync flag preservation, and a queued save processed before the
next tick. A 600-tick fast command used 75 simulation frames. With V-Sync off,
the cap checks measured about 0.31–0.39 ms per fast frame on Windows and
1.05–1.15 ms under Xvfb/llvmpipe; afterward frames took about 16.67 ms at 60 FPS
and 33.33 ms when a runtime setter changed the desired cap to 30 during stepping.
These small hidden-window fixtures establish native cap removal/restoration in
the tested backends, not a general performance bound or V-Sync presentation rate.

The Linux checks used the Windows-mounted checkout and do not establish filename
casing on a native Linux filesystem, physical window-manager close events,
native Wayland, or hardware GPU behavior. They do not establish timing
equivalence between batched and separate requests. Compare deterministic
component and simulation values rather than frame counters, FPS, or profiling
measurements.

## Identify the source snapshot and executable

- Record `git rev-parse HEAD` and `git status --short`, including relevant new
  files and dependency preparation. A commit hash alone does not identify dirty
  source being compiled. Expected prepared R3D changes are explained in
  `dependency-pitfalls.md`; do not conflate them with unrelated edits.
- Run the exact output from a successful current build. Stop on compilation or
  linking failure instead of executing an older file left at the output path.
  Distinguish build-time flags from the arguments used to launch that executable.
- Launcher prebuilt mode runs existing `build/<example>` binaries (`.exe` on
  Windows) without checking freshness. `RUNE_EXAMPLES_PREBUILT=1` forces it;
  missing Odin also selects prebuilt mode. It skips source dependency
  preparation. Verify which binary the tester ran before attributing its behavior
  to current source. See `docs/linux.md`, Run the example launcher.
- `release_check --working-tree` snapshots current nonignored files, including
  uncommitted additions, into an isolated export. The default mode exports only
  committed `HEAD` and its recorded submodule revision. Existing `build/` outputs
  are excluded. Report the mode used; a working-tree pass is not proof of the
  published commit. See `docs/release.md`, Engineering check.

Keep Windows/Linux and headless/runtime results distinct. An X11 software-rendered
pass does not establish native Wayland or physical GPU behavior; WSL builds on a
Windows-mounted checkout do not establish case-sensitive filename correctness.

## Pinned Windows directory traversal and finalization

With `dev-2026-10-nightly:84bc3fc`, a completed `core:os` Walker can leave its
last Windows `FindFirstFileW` search handle open: `dir_walker.odin` clears the
iterator file before the Windows iterator destructor reaches `FindClose`.
On 2026-10-21, a focused walk/destroy/rename reproduction failed with Windows
error 5 until that same handle was explicitly closed. This is a pinned-toolchain
observation, not a claim about later Odin releases or every access-denied error.

Rune's publisher uses `read_all_directory_by_path` recursion in
`rune_publish/main.odin` so enumeration closes before finalization; its
`main_finalization_moves_files_and_directories_without_replacing_targets` test
records inventory before moving the populated directory. If package finalization
fails only while the publisher is alive, inspect retained search/file handles
before blaming ACLs or antivirus. Do not patch a user's compiler installation to
work around this; keep the checked-in ownership fix and test the actual output.
