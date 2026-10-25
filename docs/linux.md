# Linux development

Linux AMD64 and Windows AMD64 are equal Rune development targets. The initial
Linux baseline is Ubuntu 24.04 AMD64. Other distributions may work with equivalent
packages and need their own validation. Linux ARM64 and macOS are not yet release
targets; the bundled native dependencies need separate verification.

## Verification status

The pinned compiler `dev-2026-10-nightly:84bc3fc` has passed headless validation
on Windows AMD64 and Linux AMD64. The Linux run on 2026-10-11 used Ubuntu
24.04.2 under WSL2 with glibc 2.39, HEAD `bffb14a` plus the current working
changes, and the checkout mounted from the Windows filesystem at `/mnt/d`.
This run does not verify filename casing on a native case-sensitive filesystem.

`sh tools/validate.sh --all-examples` completed successfully: 58 tool packages,
52 headless validators, 21 unit-test packages, and all 40 project-file checks
passed. The blank project, all 39 examples, and the launcher built successfully.
A separate hidden Clay UI runtime check passed through WSLg. Windows full-suite
validation and focused checks for the latest changes also passed.

Focused window verification on 2026-10-16 used the same pinned compiler with
static and shared raylib on Ubuntu 24.04 WSLg/X11. The window runtime validator
passed mode transitions, rapid switching, geometry/maximized restoration,
frame pacing, drawing/scissor pixels, and pointer checks. Shared builds also
passed all three startup modes and linked Hello World and the blank template.
This is software-rendered WSLg coverage; the native-desktop status below still
applies. See [display settings](display.md) for the window API and test commands.

Focused batch-console validation on 2026-10-24 used Ubuntu 24.04.2 WSL2, glibc
2.39, the pinned October compiler, static raylib, and `8bcea68` plus the
working-tree batch implementation. Console and focused core tests passed, along
with capture/profile rendering under isolated Xvfb and Mesa llvmpipe. Actual
callback and scene loops completed deferred commands and flushed partial replies
on mid-batch `quit` or `request_exit` between entries and during `step`/`profile`.
The Linux sender also passed against the freshly built Hello World engine.
This verifies the tested loop shutdown paths, not physical window-manager close
events, native Wayland, or hardware GPU behavior. See
[batch commands](runtime-console.md#batch-commands) for the protocol.

Fast-step checks on 2026-10-24 used that same WSL2/Xvfb configuration and
`8bcea68` plus the batch and fast-step working-tree changes. All 35 core, 20
input, and 84 console tests passed, together with the debug-console and player
profile validators. `fast_step_validation --runtime` passed 33 actual callback
and scene-loop cases, including deferred replies, input edges, queued saves,
interruption, and V-Sync flag preservation. Fast stepping completed 600 ticks in
75 simulation frames; native pacing returned to 60 FPS or the updated runtime
cap of 30 FPS after completion. This does not verify physical window-manager
close events or synchronized presentation under V-Sync. See
[fast paused stepping](runtime-console.md#fast-paused-stepping).

The [Deck staging helper](steam-deck.md) built all 39 optimized static examples
and the launcher. All 40 binaries require at most `GLIBC_2.38` and resolved their
system libraries without the isolated build environment. This verifies builds,
headless behavior, and the tested hidden UI path. Linux desktop rendering,
GPU drivers, audible playback, physical controllers, and Steam Deck hardware
remain unverified.

Earlier native-helper checks on Ubuntu 26.04.1 under WSL2 with Odin
`dev-2026-09-nightly:a2fb372` on 2026-10-07 covered compiler installation,
project creation/builds, fixture generation, console requests/replies and timeout
cleanup, and release-helper exports/reports/process cleanup. These are historical
helper checks; the October engine validation above records the current evidence.

Shell checks using Git's shell on Windows do not establish Linux support. Keep
`toolchain.json`'s `tested_platforms` limited to platforms with passing validation;
`target_platforms` records intended support separately. Record the tested revision
and distinguish headless checks from graphics, audio, and real desktop checks.

## Install dependencies

Install Git and the compiler release recorded in
[`toolchain.json`](../toolchain.json). Helpers use the native shell and standard
utilities (`awk`, `curl`, `tar`, `sha256sum`, and `timeout`). The Deck staging
helper also requires Python 3 to parse the example manifest and audit binaries.

- [Odin installation](https://odin-lang.org/docs/install/)

On Ubuntu 24.04:

```bash
sudo apt-get update
sudo apt-get install -y build-essential clang cmake curl git ca-certificates \
  libx11-dev libxrandr-dev libxi-dev libxcursor-dev libxinerama-dev \
  libgl1-mesa-dev libasound2-dev zlib1g-dev
```

Use the official GitHub repository's clone URL with `git clone --recurse-submodules`,
then run these commands from the Rune checkout:

**The submodule command installs r3d, required for 3D examples such as First Person
3D.** Run it before launching those examples; the launcher does not download the
dependency automatically. It is safe to repeat if r3d is already installed.

```bash
git submodule update --init --recursive
sh tools/prepare_r3d.sh
sh tools/install_odin.sh --destination "$PWD/build/odin-toolchain"
```

The installer downloads the platform's pinned Odin release, verifies its SHA-256,
builds missing native stb and Box2D libraries on Linux, and prints the compiler
directory to add to your `PATH`. The Box2D build uses the versioned script bundled
with Odin and downloads Box2D 3.1.1 source. Keep the compiler's
`base`, `core`, and `vendor` directories together. The installer refuses to
overwrite an existing destination. If Odin is already installed, use that
installation when its version matches the recorded toolchain. If you installed
the upstream Linux archive yourself, its native Box2D libraries are missing;
run `bash /path/to/odin/vendor/box2d/build_box2d.sh` once before building Rune.

```bash
odin version
sh tools/validate.sh --all-examples
odin build examples/hello_world -o:none -collection:rune=rune -out:build/hello_world
./build/hello_world
```

Linux outputs have no `.exe` suffix. Run examples from the engine checkout so
their relative project and asset paths resolve. Paths and filenames must match
case exactly on Linux. The default toolchain links X11; on a Wayland desktop,
install/enable XWayland. A working XWayland session does not establish native
Wayland support.

## Example launcher

From the checkout, run:

```sh
sh launcher.sh
```

You can also invoke it from another directory with
`sh /path/to/rune/launcher.sh` (quote paths containing spaces). It builds and runs
the launcher with the checkout as its working directory and writes the executable
to `build/launcher`. Compiler or launcher failures propagate to the calling shell.
The launcher requires a desktop session. With Odin on `PATH`, it builds each
selected example; without Odin, it runs the existing `build/<example>` binary.
Set `RUNE_EXAMPLES_PREBUILT=1` to select prebuilt mode explicitly. This mode
skips source dependency preparation. Windows has the matching `launcher.bat`
and uses `.exe` binaries.

D-pad or left stick browses the example list and categories, A launches, and B
exits. Keyboard and mouse controls also work. `RUNE_EXAMPLE_ARGS` forwards flags
to examples in both modes; quote values containing spaces:

```sh
RUNE_EXAMPLE_ARGS='--console-dir="build/my console"' sh launcher.sh
```

The parser groups single/double quotes and recognizes escaped whitespace, quotes,
and backslashes. It passes arguments directly to the process, without shell
expansion. Build mode inserts Odin's `--` separator before the example arguments.
See [Steam Deck examples](steam-deck.md) for a staged package with static Rune
libraries and a glibc compatibility audit.

## Native tooling

Rune supplies `.sh` helpers for Linux and matching `.bat` helpers for Windows.
Their command-line options and behavior match. Keep both implementations aligned
when changing build, validation, or release behavior.

| Task | Linux command |
| --- | --- |
| Install the pinned compiler | `sh tools/install_odin.sh --destination build/odin-toolchain` |
| Prepare initialized R3D bindings | `sh tools/prepare_r3d.sh` |
| Validate and build all examples | `sh tools/validate.sh --all-examples` |
| Check an isolated release export | `sh tools/release_check.sh --working-tree` |
| Create a project | `sh tools/new_project.sh --path ../MyGame --name 'My Game'` |
| Build a generated project | `sh /path/to/MyGame/build.sh --rune-root /path/to/rune` |
| Send a console command | `sh tools/console.sh --directory build/console --command status --json` |
| Send a console batch | `sh tools/console.sh --directory build/console --batch-file commands.txt --json` |

The Linux build helpers produce extensionless executables; Windows helpers use
`.exe`. The importer rebuild helper supports `--target Linux`; its Windows target
requires MSVC headers and the Windows SDK on a Windows host. The example mesh and
animation fixture generators also have `.sh` and `.bat` versions.

The verification status above records completed Linux checks. Other environments
and desktop behavior need the runtime and real-desktop checks below.

## Create a game

From the engine checkout, in Bash:

```bash
rune_root="$PWD"
sh tools/new_project.sh --path ../MyGame --name 'My Game'
cd ../MyGame
sh build.sh --rune-root "$rune_root" --run
```

Use `--release` for optimized builds. The game is written to `build/game`; the
build helper runs it from the game directory, including when paths contain spaces.
To launch it with the console inbox, run this from the game directory:

```bash
./build/game --console-dir=build/console
```

While it runs, use a second terminal in the game directory:

```bash
sh /path/to/Rune/tools/console.sh \
  --directory build/console --command status --json
sh /path/to/Rune/tools/console.sh \
  --directory build/console --command 'capture build/capture.png' --json
```

Use a separate inbox for each game. The same pause, step, input, inspection,
reload, and capture commands work through files on both operating systems.

## Automated runtime checks

In a desktop session, run from the engine checkout:

```bash
sh tools/validate.sh --all-examples --runtime
sh tools/release_check.sh --working-tree --runtime
```

The release check includes validation, so normally choose one command rather than
running both. Omit `--working-tree` to test the committed source and recorded submodule
revision. The check creates an isolated export and a new game under `build/`,
builds default and optimized configurations, exercises console status/pause/step,
and captures a frame. It stops only the game process it started.

For a Linux machine without a desktop, install the virtual-display packages:

```bash
sudo apt-get install -y xvfb xauth libgl1-mesa-dri
LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a -s '-screen 0 1280x720x24' \
  sh tools/release_check.sh --working-tree --runtime
```

Xvfb supplies the display; audio runtime checks still require a working playback
device. Omit `--runtime` to run checks without graphics or audio initialization.
Runtime validator processes have a 90-second timeout. Their stdout/stderr logs
are saved beside the binaries; release reports also record the OS, architecture,
shell, compiler, and display environment.

## Real desktop release checks

Run these on actual Linux desktops before declaring desktop support verified.
Record distro, session type (X11 or Wayland with XWayland), GPU/driver, compiler
version, and the tested Git commit.

| Area | Check |
| --- | --- |
| Rendering | Run 2D sprites/UI and 3D textured/skeletal examples; inspect captured frames. |
| Input | Exercise keyboard, mouse capture, gamepad input, focus loss, and rebinding. |
| Audio | Confirm audible sound/music, mixer volume/mute, and the selected output device. |
| Hot reload | Save valid scene and texture changes; confirm updates. Invalid scene JSON must preserve the active world. |
| Console | Inspect, pause, step, override input, reload, and capture through the inbox. |
| Windowing | Resize, minimize/restore, switch fullscreen/borderless/windowed, and close normally. |
| DPI and monitors | Test scaling, pointer alignment, moving between monitors, and window restoration. |
| Project workflow | Create and build a game outside the engine folder, including paths containing spaces. |

Virtual-display checks do not replace these tests. Native Wayland support and
different GPU drivers need their own evidence; do not infer them from an X11 pass.
