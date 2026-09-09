# Linux development

Linux AMD64 and Windows AMD64 are equal Rune development targets. The initial
Linux baseline is Ubuntu 24.04 AMD64. Other distributions may work with equivalent
packages and need their own validation. Linux ARM64 and macOS are not yet release
targets; the bundled native dependencies need separate verification.

## Verification status

Validation is run locally on each platform. Linux execution has not yet been
verified from this Windows checkout: WSL is not installed. Keep `toolchain.json`'s
`tested_platforms` limited to platforms with actual passing runs; `target_platforms`
records intended support separately. Record the Linux run and compiler revision
after completing validation on a Linux machine.

## Install dependencies

Install Git, PowerShell 7, and the compiler release recorded in
[`toolchain.json`](../toolchain.json). PowerShell runs on Linux and is only needed
for the helper scripts. Games themselves do not depend on it.

- [PowerShell installation for Linux](https://learn.microsoft.com/en-us/powershell/scripting/install/linux-overview)
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

```bash
git submodule update --init --recursive
pwsh -NoProfile -File tools/install_odin.ps1 -Destination "$PWD/build/odin-toolchain"
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
pwsh -NoProfile -File tools/validate.ps1 -AllExamples
odin build examples/hello_world -collection:rune=rune -out:build/hello_world
./build/hello_world
```

Linux outputs have no `.exe` suffix. Run examples from the engine checkout so
their relative project and asset paths resolve. Paths and filenames must match
case exactly on Linux. The default toolchain links X11; on a Wayland desktop,
install/enable XWayland. A working XWayland session does not establish native
Wayland support.

## Create a game

From the engine checkout, in Bash:

```bash
rune_root="$PWD"
pwsh -NoProfile -File tools/new_project.ps1 -Path ../MyGame -Name 'My Game'
cd ../MyGame
pwsh -NoProfile -File build.ps1 -RuneRoot "$rune_root" -Run
```

Use `-Release` for optimized builds. The game is written to `build/game`; the
build helper runs it from the game directory, including when paths contain spaces.
To launch it with the console inbox, run this from the game directory:

```bash
./build/game --console-dir=build/console
```

While it runs, use a second terminal in the game directory:

```bash
pwsh -NoProfile -File /path/to/Rune/tools/console.ps1 \
  -Directory build/console -Command status -Json
pwsh -NoProfile -File /path/to/Rune/tools/console.ps1 \
  -Directory build/console -Command 'capture build/capture.png' -Json
```

Use a separate inbox for each game. The same pause, step, input, inspection,
reload, and capture commands work through files on both operating systems.

## Automated runtime checks

In a desktop session, run from the engine checkout:

```bash
pwsh -NoProfile -File tools/validate.ps1 -AllExamples -Runtime
pwsh -NoProfile -File tools/release_check.ps1 -WorkingTree -Runtime
```

The release check includes validation, so normally choose one command rather than
running both. Omit `-WorkingTree` to test the committed source and recorded submodule
revision. The check creates an isolated export and a new game under `build/`,
builds default and optimized configurations, exercises console status/pause/step,
and captures a frame. It stops only the game process it started.

For a Linux machine without a desktop, install the virtual-display packages:

```bash
sudo apt-get install -y xvfb xauth libgl1-mesa-dri
LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a -s '-screen 0 1280x720x24' \
  pwsh -NoProfile -File tools/release_check.ps1 -WorkingTree -Runtime
```

Xvfb supplies the display; audio runtime checks still require a working playback
device. Omit `-Runtime` to run checks without graphics or audio initialization.
Runtime validator processes have a 90-second timeout. Their stdout/stderr logs
are saved beside the binaries; release reports also record the OS, architecture,
PowerShell version, compiler, and display environment.

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
