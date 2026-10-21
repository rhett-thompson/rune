# Game publishing

The first publishing milestone is one command that turns a Rune game into a
portable Windows AMD64 or Linux AMD64 package. Players need neither Odin nor a
Rune checkout. A working graphics/audio environment and the documented system
libraries remain runtime requirements.

This plan covers game distribution. Engine source releases have their own
[release checks](release.md). Executable-relative startup and the player build
profile, `publish.json`, and native Windows/Linux publishing commands are
available. Broader user-data helpers, asset pruning, and fresh-machine/hardware
package qualification remain follow-up work.

## Delivery sequence

1. **Portable runtime and player build profile.** Resolve packaged resources
   consistently, separate writable user data from the installation, and give
   Windows and Linux builds an explicit player profile.
2. **Windows/Linux publishing command and verified packages.** Build a game,
   stage its configured content and required native dependencies in a fresh
   directory, audit the result, and create an archive. Verify representative 2D
   and 3D packages on both targets.
3. **Asset dependency inspection and package-size improvements.** Expand
   diagnostics, then add optional dependency-based stripping where its limits
   can be made explicit.

Each phase must preserve the code-first workflow and support standalone game
projects outside the engine checkout.

## Portable startup

A published package contains the executable, `project.json`, and the configured
content tree. Default player startup finds the project relative to the executable,
so launching from a shortcut or an unrelated working directory has the same
result. Preserve an explicit project-path override for development and tools.
Normal developer builds must retain their supported project-launch workflow.

The project directory is the resource root shared by core asset loading, 3D
rendering, and game code. Keep ordinary assets project-relative and preserve the
existing `prefab://` ownership rules. Expose the resolved root to games and
optional subsystems so custom asset loading can follow the same convention.
Changing the caller's working directory must not silently change which assets
are loaded.

Saves, settings, input bindings, and logs need writable per-game user storage.
Use a stable game identity to choose the Windows/Linux user-data location,
independent of the executable's location and current working directory. Installed
resources may be read-only. Keep resource lookup separate from user-data lookup
and retain explicit paths where callers need them. Report startup and storage
failures with useful paths and error details.

## Player build profile

The profile is explicit and available through the Windows and Linux generated
project build helpers. Optimization alone does not select it: existing release
builds remain useful for development diagnostics.

Player builds disable the developer console and command inbox, JSON/asset hot
reload, engine gizmos, bridge debug grids/collider wireframes, and FPS title
updates. Runtime requests must not re-enable
developer access in a player build. Preserve ordinary game UI, input, errors,
and useful diagnostics. Document which debug APIs become inert and keep normal
development builds usable for iteration.

## Available startup and build workflow

Newly generated games call `rune.init_project()`. Its default path is anchored to
the running executable on Windows and Linux:

| Build | Default project path relative to executable |
| --- | --- |
| Development, including `--release` | `../project.json` (binary in the game's `build/`) |
| Player (`--player`) | `project.json` (binary beside packaged content) |

There is no CWD search or parent-project fallback in player mode. To select a
different layout, pass an executable-relative or absolute path to
`rune.init_project(path)`. `rune.executable_project_path(path)` returns the owned
absolute path without opening a window. Existing `rune.init(path)` keeps explicit
CWD-relative/absolute path selection; successful initialization now retains an
absolute `engine.project_directory`. Neither entry point changes CWD.

Pass `engine.project_directory` to `r3d_bridge.init`, and resolve custom file reads
with `rune.resource_path(&engine, "assets/file.json")`. That helper returns an
owned path; delete it with the allocator used to create it. It preserves explicit
absolute paths and parent traversal for tools, so it does not enforce package
containment. Raw relative OS/raylib reads still require migration in game code.

The copied game helpers accept these options on Windows and Linux:

```bat
build.bat --rune-root ../rune --player
```

```sh
sh build.sh --rune-root ../rune --player
```

`--player` adds `-o:speed`, `-define:RUNE_PLAYER=true`, and
`-define:RAYLIB_SHARED=false`. Manual builds can use the same flags with Rune's
compiler-lock wrappers and the game's usual collections/linker settings.
`rune.Player_Build` exposes the compile-time mode. `--release` continues to select
optimization alone. Both retain assertions and runtime checks.

The helpers still output `build/game.exe` or `build/game`; they do not yet create
a distributable folder. Stage the executable and the complete game content into
a new folder manually, preserving paths:

```text
My Game/
  game.exe                  # game on Linux
  project.json
  input/default.input.json
  scenes/main.scene.json
  assets/                   # plus every other game content folder/file
```

Include applicable licenses/notices when distributing that folder. `--player`
cannot be combined with `--run` because the build helper has not staged content.
Missing project/startup-scene failures in the generated entry point exit nonzero
and report the attempted path or scene error. Existing generated games must
adopt the updated entry point and helpers; engine updates do not replace copies.

Player console registration, execution, and remote-inbox enable calls return
false; guard registration assertions with `when !rune.Player_Build`. Logging
through `rune.developer_console` remains available with bounded history and
stderr output. `--console-dir` is ignored in player builds. Gameplay pause,
input, cursor control, and authored game UI remain available. Custom debug
drawing through raw rendering APIs remains the game's responsibility.

Configured saves already default to OS user-data/game ID/saves. Choose a stable
game ID and use OS user-data storage for custom settings, input binding files,
and file logs as well. Startup does not redirect arbitrary game file writes.
`publish.json` supplies a distribution identity; it does not automatically
change game-owned save IDs or redirect writes. A general per-game storage helper
is still future work.

`tools/validate.bat` and `tools/validate.sh` run the headless player-profile
validator in both development and player modes; core tests cover executable and
resource path resolution. These checks do not establish full-package or target
hardware compatibility. The acceptance checks below remain the publishing gate.

## Startup/profile verification context

The startup/profile slice was checked with the pinned
`dev-2026-10-nightly:84bc3fc` toolchain on 2026-10-21: Windows AMD64 with native
Win32/GLFW and NVIDIA OpenGL, and Ubuntu 26.04 AMD64 under WSL2 with WSLg/X11
and Mesa llvmpipe. Both platforms passed the 26 core and 79 console development
tests, the two player-mode startup tests in `rune/core/startup_test.odin`, and
the bridge suites (48 development tests and 49 player tests). The
`tools/player_profile_validation` fixtures passed in both profiles, and Hello 3D
built in both profiles on each OS.

Generated development/player helper builds and relocated runtime probes passed
on both platforms. The probes loaded input, custom files, and a GPU texture from
the resolved root, shared that root with the 3D bridge, rendered primitive 3D
scenes, and changed scenes. The Linux relocated probe ran on a native
case-sensitive filesystem. The unstaged player exited nonzero despite a valid
project in its CWD/parent, and `--console-dir` did not create a player inbox.

This is focused startup/profile coverage, not a full engine release check or a
fresh-machine package qualification. Linux was built on Ubuntu 26.04; its results
do not establish the older distribution ABI baseline planned for packaging.
Human visual review, audible playback, physical controllers, a read-only install,
and saves/settings surviving a package upgrade were not verified here.

## Publishing configuration and build

New projects include `publish.json` alongside `project.json`, with local
[schema completion](../schemas/publish.schema.json). Existing games can add:

```json
{
  "$schema": "schemas/publish.schema.json",
  "id": "my-game",
  "name": "My Game",
  "version": "0.1.0",
  "executable": "my-game",
  "targets": ["windows-amd64", "linux-amd64"],
  "content": ["project.json", "input/", "scenes/", "assets/"],
  "licenses": ["credits.txt"],
  "build": {
    "collections": {"shared": "../Shared Code"},
    "defines": {"ENABLE_MULTIPLAYER": true, "MAX_PLAYERS": 4},
    "extra_linker_flags": ""
  }
}
```

Only list files/directories that exist in that game. `licenses` and `build` are
optional. The generated minimal config includes the starter's existing content
and an empty game-license list; add asset credits and notices as needed.

| Setting | Purpose |
| --- | --- |
| Stable game ID and version | Identify writable storage and distribution output. |
| Executable name | Give each platform's binary a predictable package name. |
| `content` | Explicit files and complete directories, including code-loaded resources, with their relative paths preserved. |
| `licenses` | Additional game-specific notices, copied at their game-relative paths. |
| `build.collections` | Additional named Odin collections, resolved from the game directory; sibling source dependencies may use `../`. |
| `build.defines` | Boolean, signed 64-bit integer, finite float, or string compiler defines. |
| `build.extra_linker_flags` | An optional string passed as one Odin linker-option argument. |

The parser rejects unknown fields, malformed/duplicate JSON keys, unsupported
targets, unsafe names/paths, and attempts to override the reserved `rune`/`r3d`
collections or `RUNE_PLAYER`/`RAYLIB_SHARED` defines. Content uses forward slash
relative paths without `..`; build-only collection paths may refer to siblings.
`executable` is extensionless and cannot be a Windows device name or `licenses`.
`version` is a distribution version, independent of save-format versions.

The publisher supplies both engine collections and always builds optimized
player code with static raylib and runtime checks enabled. It does not call the
game's copied `build.bat`/`build.sh`; put required custom collections/defines in
`publish.json`. Build commands use argv rather than shell evaluation. The pinned
Windows Odin compiler cannot preserve literal double quotes inside argument
values; such string defines/linker options fail explicitly rather than being
silently changed. Spaces, apostrophes, backslashes, and typed scalar values are
supported. Linux argv preserves literal double quotes too.

From the game directory, invoke the engine's command:

```bat
..\rune\tools\publish.bat --project .
```

```sh
sh ../rune/tools/publish.sh --project .
```

The default output is
`GAME_ROOT/build/publish/<id>-<version>-<target>/`, with an adjacent `.zip` on
Windows or `.tar.gz` on Linux. `--output <new-package-directory>` overrides the
folder; relative command-line paths use the caller's working directory. The
directory and archive must both be absent. The archive contains one enclosing
folder with the same name as the output directory. Run the executable directly
after extraction; its adjacent `project.json` supplies the resource root.

`--target windows-amd64|linux-amd64` defaults to the current host and must be
enabled in the config; cross-compilation is rejected. `--odin <compiler>` or
`ODIN` selects the game compiler (the bootstrap launcher still requires Odin on
PATH). The compiler must match the release in `toolchain.json`. The launchers
build the shared `tools/publisher` implementation through Rune's compiler lock;
game builds cooperate with the same lock and release it before packaging.
The commands need no additional scripting runtime. Linux also needs `flock`,
`readelf`, `mktemp`, and `tar`; Windows uses built-in CScript/tar and its MSVC build tools.

Build and validate in a fresh sibling staging directory. Copy content, validate
known references, build the game, audit dependencies, hash every staged file,
and create the archive before exposing the final package. Existing outputs are
never replaced, including at the final native move. Failure leaves its staging
directory for inspection and exits nonzero; choose a new output for a new release.
The Linux output filesystem must support atomic no-replacement renames. Some
WSL Windows-mounted filesystems do not; select `--output` on a native Linux
filesystem in that case. The publisher reports this rather than weakening its
no-overwrite guarantee.
An exceptional failure during the two final moves can leave the completed
package folder with its archive still in the reported staging directory.

Build Windows packages on Windows and Linux packages in a defined Linux build
environment. The output `manifest.json` records config and config checksum,
compiler, source revisions/working-tree status when Git metadata is available,
native source pins, dependency audits, and sorted file sizes/SHA-256 hashes. Its
file inventory precedes the manifest itself, so it does not hash itself.
The config checksum hashes the same initial bytes used to parse the build
configuration. Generated/untracked games are marked unverified when the parent
repository tracks no files under their root.
Game code is included only when explicitly selected in `content`.

Games using r3d receive its engine collection automatically. Additional game
collections/defines use the same publishing workflow. A successful 2D template
build is insufficient evidence that arbitrary game build requirements work.

Windows PE audits require AMD64 executables and inspect ordinary and delayed
imports. The bundled native libraries use the dynamic Microsoft C++ runtime.
When needed, publishing finds an official installed AMD64 CRT through
`VCToolsRedistDir` or the VC-tools-qualified Visual Studio installation reported
by `vswhere`. It copies only the required allowlisted runtime DLLs and their
dependency closure, auditing each DLL. Detected VS third-party notices are
included when present. For a specific build environment use
`--windows-runtime-directory <official-AMD64-CRT-directory>` and optionally
`--windows-runtime-license <notice-file>`. No DLLs are downloaded or taken from
arbitrary PATH entries. Unknown non-system dependencies fail instead of being
omitted; the manifest lists the bundled DLLs. Include any additional applicable
redistributable notices explicitly.

Linux ELF audits require AMD64 and a recognized GNU loader (or no interpreter
for a static binary). `--glibc-max 2.39` is the default symbol-version ceiling,
matching Rune's Ubuntu 24.04 baseline; an intentional alternative ceiling is
recorded in the manifest. Build in a suitable SDK/sysroot to support that
baseline. System graphics/audio libraries and, for 3D, C++/zlib libraries remain
target-machine requirements. The audit records required sonames and symbol
versions, rejects shared Rune libraries and unknown direct dependencies, and
does not run `ldd`. A glibc ceiling alone does not prove C++ ABI or driver support.
ELF search paths may be empty or the exact executable-relative `$ORIGIN`/`${ORIGIN}`
(`/` suffix allowed, as emitted by the pinned compiler). Other RPATH/RUNPATH
overrides, path-bearing shared-library names, and app-local replacements for
required Linux system sonames are rejected; custom shared-library packaging is
outside this version's scope.

## Content and output

JSON and assets remain loose files in this version. Publishing copies complete
explicit content roots, including empty directories, without pruning. It preserves paths used by scenes,
prefabs, animation files, model sidecars, and game code. Odin can select paths at
runtime, so a static scanner cannot discover every required file.

Inspect known asset references and report missing files, paths escaping the
configured package, unresolved dependencies, and filename case conflicts. Reject
ambiguous destination collisions. Inspection is a diagnostic aid, not proof that
all dynamically loaded resources were found. Full dependency scanning and
optional unused-file stripping belong to phase 3.

Current staged validation checks every recognized included scene, nested
prefabs, built-in component resource fields, supported Rune asset descriptors,
and glTF/GLB buffer/image or OBJ/MTL sidecars. It rejects paths outside the stage,
references omitted from the include list, case mismatches, and all symbolic-link
or Windows reparse/junction ancestors. Unknown custom JSON fields and arbitrary
Odin file reads cannot be inferred; keep their complete folders in `content` and
exercise the resulting package. MTL texture options currently require a plain
reviewed sidecar path and fail with a diagnostic instead of guessing the filename.

Publishing creates a fresh game directory, then a Windows ZIP or Linux tar.gz.
Include applicable Rune, native-library, and game-asset licenses/notices. Write a
manifest recording versions, included files, checksums, and dependency audit
results. Engine/toolchain notices are collected conservatively under the
reserved `licenses/rune/` directory; game notices do not establish missing asset
permissions. This reuses the [Deck staging](steam-deck.md) audit approach with a
single-game package layout.

## Acceptance checks

For both Windows AMD64 and Linux AMD64, move the completed package away from its
source tree and launch from an unrelated directory in an environment without
Odin or a Rune checkout. Verify a generated 2D game first, then a representative
3D game before declaring the publishing milestone complete.

- Startup and content loading work with spaces in paths and a read-only install
  directory. Linux validation includes a case-sensitive filesystem.
- Scene transitions, nested prefabs, model sidecars, and assets loaded directly
  by game code work from the relocated package.
- Saves, settings, input bindings, and logs use writable per-game storage and
  survive restart and package relocation.
- The player profile prevents console/inbox access and developer reload/overlay
  behavior while gameplay, input, and error reporting remain functional.
- Archives contain the expected files, notices, and manifest; native dependency
  audits pass against the declared platform baseline.

Record OS/distribution, architecture, compiler, source revision, and dependency
baseline for each result. Separate build/headless coverage from windowed
rendering, input, and audible playback checks. Existing WSL or example-staging
results do not establish fresh-machine game-package coverage.

## Publishing verification context

On 2026-10-21, the publisher's 24 focused tests passed on Windows AMD64 and
Ubuntu 26.04 AMD64 under WSL2 using `dev-2026-10-nightly:84bc3fc`. Generated 2D
and representative 3D projects produced Windows ZIP and Linux tar.gz packages.
Independent extraction and SHA-256 checks matched their manifests; Linux archive
executable permissions and empty content directories were preserved. Custom
collections and boolean/integer/float/string defines compiled on both hosts.

Relocated/extracted 3D packages loaded input mappings, custom files, GPU textures,
nested prefabs, imported OBJ/MTL/PNG sidecars, Rune materials, and scene transitions
from an unrelated working directory. Player console/inbox requests stayed
disabled. Windows used native Win32/GLFW and NVIDIA OpenGL; Linux used WSLg/X11
with Mesa llvmpipe on native case-sensitive Linux storage, with the extracted
installation made read-only. Audio initialized, but audible playback and human
visual review were not checked. Runtime launches excluded Odin/Rune environment
paths. Windows packages included the audited installed VC CRT closure.

Negative cases covered missing includes/assets/sidecars, absolute source
references, wrong-host targets, and existing outputs. Existing output markers
were preserved. Concurrent Windows publish/help launchers and a configuration
edit during compilation passed: each launcher used a separate tool executable,
and the manifest retained the initially parsed config checksum.

The Ubuntu 26.04 build required glibc 2.43. The default 2.39 audit correctly
rejected it; successful Linux packages explicitly selected `--glibc-max 2.43`.
These results do not qualify the Ubuntu 24.04 ABI baseline. WSL Windows storage
rejected atomic no-replacement finalization, so successful Linux outputs used
native Linux storage. Fresh supported systems, physical controllers, other GPUs,
and saves/settings surviving package upgrades remain unverified. These focused
checks do not replace the full engine release checks.

## Follow-up scope

Store uploads, installers, signed distribution workflows, packed asset archives,
cross-compilation, additional architectures, and macOS follow after the initial
portable Windows/Linux packages. They do not block the first publishing command.
