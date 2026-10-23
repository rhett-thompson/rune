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
| Window modes or shared-raylib linking | `tools/window_validation` for settings; compile a separate shared target with `-define:RAYLIB_SHARED=true` | `window_validation --runtime`; run `--startup-windowed`, `--startup-borderless`, and `--startup-fullscreen` in separate processes when startup modes matter |
| Audio ownership, mixing, stopping, or preload | `tools/mixer_validation` and `tools/audio_stop_validation` for configuration | Both validators with `--runtime`, using a working playback backend |
| Navmesh bake coverage or path detours | `rune/navigation` tests, `tools/navigation_bake_validation`, and headless `tools/navigation_3d_validation`; compare actual route lengths on the reported bake/query settings | `navigation_3d_validation --runtime` when visible agent motion or rendered navigation is the symptom |
| Terrain editing or reload retention | `tools/terrain_validation` for PNG/R16 decoding, CPU data ownership, native collision, corrupt-heightmap retention and recovery | `terrain_validation --runtime` for GPU chunk replacement, invalid-reload retention, materials and instanced details |

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
