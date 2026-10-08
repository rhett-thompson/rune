# Linux development

Linux AMD64 and Windows AMD64 are equal Rune development targets. The initial
Linux baseline is Ubuntu 24.04 AMD64. Other distributions may work with equivalent
packages and need their own validation. Linux ARM64 and macOS are not yet release
targets; the bundled native dependencies need separate verification.

## Verification status

The current pinned compiler is `dev-2026-10-nightly:84bc3fc`, validated on
Windows AMD64. Full engine validation with October Odin and the current checkout
is pending on Linux; `toolchain.json` retains only Windows in `tested_platforms`.
The September results below are historical and do not establish October support.

The R3D 0.11 importer archive was cross-compiled for Linux AMD64. Native Ubuntu
shell syntax and binding preparation checks pass, including pristine release
archives without Git metadata. Linux compiler, renderer, and animation runtime
regressions still need a native Odin installation and validation run.

The native helpers were exercised on Ubuntu 26.04.1 LTS AMD64 under WSL2 with Odin
`dev-2026-09-nightly:a2fb372` on 2026-10-07. Compiler installation, project creation
and builds, fixture generation, and console requests, replies, and timeout cleanup
passed. Release-helper fixtures also covered exports, reports, and process cleanup.

The headless engine run used commit `ea6839be31d53ac0e0a72321778671a332dd4211`
with the new helpers and the recorded r3d submodule on a case-sensitive Linux
filesystem. All 96 build steps passed, including 53 tool packages, the blank project,
39 games, and the launcher; all 40 project-file validations passed. Of 51 headless
validators, 49 passed. Prefab path resolution and save-directory validation failed
when invoked directly as well as through the helper. Six of seven unit-test packages
passed; the third-person package reported a failure and stalled, so its process was
stopped. A complete headless pass and Linux desktop verification remain pending;
this run does not validate the independently changing engine code in the working
checkout.

Shell checks using Git's shell on Windows do not establish Linux support. Keep
`toolchain.json`'s `tested_platforms` limited to platforms with passing validation;
`target_platforms` records intended support separately. Record the tested revision
and distinguish headless checks from graphics, audio, and real desktop checks.

## Install dependencies

Install Git and the compiler release recorded in
[`toolchain.json`](../toolchain.json). Helpers use the native shell and standard
utilities (`awk`, `curl`, `tar`, `sha256sum`, and `timeout`); no additional scripting
runtime is required.

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
odin build examples/hello_world -collection:rune=rune -out:build/hello_world
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
The launcher requires a desktop session and Odin on `PATH`.
Windows has the matching `launcher.bat`.

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

The Linux build helpers produce extensionless executables; Windows helpers use
`.exe`. The importer rebuild helper supports `--target Linux`; its Windows target
requires MSVC headers and the Windows SDK on a Windows host. The example mesh and
animation fixture generators also have `.sh` and `.bat` versions.

These portability choices still require actual Linux validation; the verification
status above distinguishes intended support from completed platform testing.

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
