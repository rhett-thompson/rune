# Game publishing

The first publishing milestone is one command that turns a Rune game into a
portable Windows AMD64 or Linux AMD64 package. Players need neither Odin nor a
Rune checkout. A working graphics/audio environment and the documented system
libraries remain runtime requirements.

This plan covers game distribution. Engine source releases have their own
[release checks](release.md). Executable-relative startup and the player build
profile, `publish.json`, and native Windows/Linux publishing commands are
available. Package content comes from the project, its asset catalog, and
their dependencies. Broader user-data helpers and fresh-machine/hardware package
qualification remain follow-up work.

## Delivery sequence

1. **Portable runtime and player build profile.** Resolve packaged resources
   consistently, separate writable user data from the installation, and give
   Windows and Linux builds an explicit player profile.
2. **Windows/Linux publishing command and verified packages.** Build a game,
   stage its selected content and required native dependencies in a fresh
   directory, audit the result, and create an archive. Verify representative 2D
   and 3D packages on both targets.
3. **Asset dependency inspection and package-size improvements.** Expand
   supported reference formats and diagnostics for dependency-based packaging.

Each phase must preserve the code-first workflow and support standalone game
projects outside the engine checkout.

## Portable startup

A published package contains the executable, `project.json`, `assets.json`, and
the selected resources. Default player startup finds the project relative to
the executable, so launching from a shortcut or an unrelated working directory
has the same result. Preserve an explicit project-path override for development
and tools.
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

Pass `engine.project_directory`, `settings = engine.project.render_3d`, and
`worker_pool = engine.worker_pool` to `r3d_bridge.init` to apply project shadow
map sizes and optional terrain CPU workers, and resolve custom file reads
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
  assets.json
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
  "output_directory": "dist",
  "licenses": ["credits.txt"],
  "build": {
    "collections": {"shared": "../Shared Code"},
    "defines": {"ENABLE_MULTIPLAYER": true, "MAX_PLAYERS": 4},
    "extra_linker_flags": ""
  }
}
```

`output_directory`, `licenses`, and `build` are optional. Generated games include an empty
game-license list and a separate `assets.json` with empty `assets` and
`directories` maps. Add asset credits and notices as needed.

| Setting | Purpose |
| --- | --- |
| Stable game ID and version | Name distribution outputs; configure game-owned save IDs separately. |
| Executable name | Give each platform's binary a predictable package name. |
| `output_directory` | Parent directory for the package folder and archive, relative to the game root. Defaults to `build/publish`. |
| `licenses` | Game-specific notice files and directory trees, copied at their game-relative paths. |
| `build.collections` | Additional named Odin collections, resolved from the game directory; sibling source dependencies may use `../`. |
| `build.defines` | Boolean, signed 64-bit integer, finite float, or string compiler defines. |
| `build.extra_linker_flags` | An optional string passed as one Odin linker-option argument. |

The parser rejects unknown fields, malformed/duplicate JSON keys, unsupported
targets, unsafe names/paths, and attempts to override the reserved `rune`/`r3d`
collections or `RUNE_PLAYER`/`RAYLIB_SHARED` defines. Resource and license paths
are project-relative and use forward slashes without `..`. Build-only collection
paths may refer to siblings.
`executable` is extensionless and cannot be a Windows device name or `licenses`.
`version` is a distribution version, independent of save-format versions.

The publisher supplies both engine collections and always builds optimized
player code with static raylib and runtime checks enabled. Windows player
executables use `-subsystem:windows`, so launching them does not create a console
window; the PE audit verifies that GUI subsystem before packaging. It does not call the
game's copied `build.bat`/`build.sh`; put required custom collections/defines in
`publish.json`. Build commands use argv rather than shell evaluation. The pinned
Windows Odin compiler cannot preserve literal double quotes inside argument
values; such string defines/linker options fail explicitly rather than being
silently changed. Spaces, apostrophes, backslashes, and typed scalar values are
supported. Linux argv preserves literal double quotes too.

The standalone [Rune Publish command-line tool](../rune_publish/README.md) lives
in `rune_publish/`. From the game directory, invoke it through the engine's
compatibility launchers:

```bat
..\rune\tools\publish.bat --project .
```

```sh
sh ../rune/tools/publish.sh --project .
```

By default, the publisher creates
`GAME_ROOT/build/publish/<id>-<version>-<target>/`. Set `output_directory` to
place that versioned folder under another directory relative to the game root,
such as `dist`. Use a portable path with forward slashes and an optional
trailing slash.

`--output <new-package-directory>` overrides the entire package path, including
its name. Relative command-line paths resolve from the caller's working
directory. The archive sits beside the package folder, with the same name plus
`.zip` on Windows or `.tar.gz` on Linux. Both paths must be absent before
publishing. The archive contains one enclosing folder with the package's name.
After extraction, run the executable directly. Its adjacent `project.json`
supplies the resource root.

Add `--dry-run` to validate the package plan and any catalog input hashes
without compiling the game or creating a package. The launcher still builds the
small publisher tool. Native import audits run after the game build.

`--target windows-amd64|linux-amd64` defaults to the current host and must be
enabled in the config; cross-compilation is rejected. `--odin <compiler>` or
`ODIN` selects the game compiler (the bootstrap launcher still requires Odin on
PATH). The compiler must match the release in `toolchain.json`. The launchers
build the `rune_publish/` application through Rune's compiler lock;
game builds cooperate with the same lock and release it before packaging.
For direct locked build/test commands and the `rune_publish` executable's
options and exit codes, see its [README](../rune_publish/README.md).
The commands need no additional scripting runtime. Linux also needs `flock`,
`readelf`, `mktemp`, and `tar`; Windows uses built-in CScript/tar and its MSVC build tools.

The publisher plans and validates dependencies before compiling the game. It
then uses a fresh sibling staging directory to copy selected content, validate
the staged references, build the game, audit native dependencies, hash every
staged file, and create the archive before exposing the final package. Existing
outputs are never replaced, including at the final native move. A failure after
staging starts leaves the staging directory for inspection and exits nonzero.
Choose an output outside directory trees selected through the catalog or licenses.
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
file inventory includes `assets.json` and precedes the manifest itself.
The config checksum hashes the same initial bytes used to parse the build
configuration. Generated/untracked games are marked unverified when the parent
repository tracks no files under their root.

Native source pins include `third_party/rune-image/sources.json` for Rune's
private memory-image decoder, alongside the patched R3D components. Its private
stb header, TLS patch, wrapper, build pins, and Windows/Linux AMD64 static
archives are documented in [the decoder native README](../third_party/rune-image/README.md).
Normal game builds link the selected checked-in archive and need no Zig/native
rebuild step. There is no separate decoder DLL to stage; normal CRT/system
dependency audits still apply, including Linux's `libm` dependency.

Games using r3d receive its engine collection automatically. Additional game
collections/defines use the same publishing workflow. A successful 2D template
build is insufficient evidence that arbitrary game build requirements work.

Windows PE audits require AMD64 executables and inspect ordinary and delayed
imports. The bundled native libraries use the dynamic Microsoft C++ runtime.
Game compilation uses `tools/find_msvc.bat` to select a complete MSVC toolset.
When needed, the publisher finds an official installed AMD64 CRT through
`VCToolsRedistDir` or by inspecting the redist trees of installations reported
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

Rune Publish includes the root `project.json` and `assets.json`, preserving
project-relative paths in the package. It follows the startup scene and input
mappings in `project.json`. In `assets.json`, each name under `assets` selects
a file and each name under `directories` selects a complete directory tree,
including empty directories. Declare resources the publisher cannot reach
through authored references, such as scenes loaded later by game code. Use the
same catalog for named runtime lookups through [`rune:assetcatalog`](assetcatalog.md).
Authored resource fields continue to use ordinary filenames.

Traversal follows built-in scene and prefab resource fields, Rune material,
animation, tileset and terrain descriptors, and glTF/GLB or OBJ/MTL sidecars.
Existing `<model>.materials.json` bindings and their materials are included with
their models. MTL textures require plain sidecar paths. The planner reports
missing references, paths outside the game, filename case mismatches, and
symbolic-link or Windows reparse-point ancestors in selected paths.

Game licenses are selected independently through `publish.json`, including
complete directory trees when listed as directories. Shared selections with
exactly the same spelling are copied once. Game code and other source files
are packaged only when selected. JSON and resources remain loose files.

### Declare custom dependencies

`assets.json` can declare dependencies from custom formats and pin the inputs
used to generate the catalog. In this example, selecting the custom level also
includes its binary data.

```json
{
  "$schema": "schemas/assetcatalog.schema.json",
  "version": 1,
  "assets": {"level.start": "assets/levels/start.level.json"},
  "directories": {"dir.dialogue": "assets/dialogue"},
  "dependencies": {
    "assets/levels/start.level.json": ["assets/data/start.bin"]
  },
  "inputs": {
    "src/": "<sha256-of-source-directory>"
  }
}
```

`dependencies` and `inputs` are optional. Dependency keys name project-relative
files. Each value lists files or complete directory trees to include when the
source file is reached. Declare paths that only appear in custom JSON or Odin
code. Games can generate these declarations from their own procedural formats
and code conventions.

The publisher checks `inputs` before compiling. A file input hashes its bytes
with SHA-256. For a directory input, end its key in `/`, recursively sort its
file paths relative to that directory, and hash the concatenation of each UTF-8
path, a NUL byte, the lowercase SHA-256 of its file bytes, and a LF byte. Empty
directories do not affect the checksum. Input trees reject links, nonportable
names, and case conflicts. Regenerate the catalog after an input changes. The
input declarations check source files without adding them to the package.

Exercise the extracted game, including resources loaded dynamically, before
distributing it.

Publishing creates a fresh game directory, then a Windows ZIP or Linux tar.gz.
Include applicable Rune, native-library, and game-asset licenses/notices. Write a
manifest recording versions, included files, checksums, and dependency audit
results. Engine/toolchain notices are collected conservatively under the
reserved `licenses/rune/` directory; game notices do not establish missing asset
permissions. This reuses the [Deck staging](steam-deck.md) audit approach with a
single-game package layout.
The conservative engine notice set includes the private decoder's
`LICENSE.stb_image`, README, source-pin JSON, and TLS patch under
`licenses/rune/third_party/rune-image/`, together with Rune's root zlib notice.
This private header has its own source pin; the Odin vendor stb notice retained
for other engine paths does not replace it.

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

On 2026-11-09, all 40 publisher tests and both asset catalog tests passed on
Windows AMD64 with Odin `dev-2026-10-nightly:84bc3fc` and MSVC. The Windows and
Ubuntu 24.04 WSL2 generators produced projects with local catalog schema links.
A Windows dry run validated a catalog-backed fixture, and the regular Windows
launcher found MSVC and its AMD64 CRT without developer-shell variables.
The extracted ZIP matched all 133 manifest file hashes. Its relocated player
loaded the startup scene, a catalog-named scene and prefab, a named directory
child, and a custom dependency from an unrelated working directory with
Odin and Rune paths removed. This run covered hidden-window startup and
asset loading. Linux coverage was limited to project generation and schema checks.

A Windows launcher check from outside a generated game's directory created
readable ZIPs and package folders under the default parent, a game-relative
`output_directory` containing spaces, and a caller-relative `--output` override.

Earlier releases used a separate publishing inventory and opt-in dependency
selection. The following results describe those earlier implementations.

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

The earlier opt-in dependency selection was additionally checked on Windows
AMD64 with the same pinned compiler. All 34 publisher tests passed, including
dependency cycles, runtime model material defaults, source-input drift, license
overlap, and dry runs.
A pruned game package passed independent archive checksums and relocated startup
in its menu, gameplay, editor, combat, and model gallery scenes. The game-owned
dependency generator's five tests passed on Windows and Ubuntu under WSL.
These checks did not run the native Linux pruning binary, exercise every game
interaction, or verify audible playback and fresh-machine compatibility.

The Windows GUI-subsystem fix passed all 35 publisher tests with that toolchain.
The rebuilt game passed archive checksum validation, relocated rendering/startup,
and both redirected and shell launches. An isolated Win32 `AttachConsole` probe
could attach to the previous CUI executable and reported no console for the GUI
executable after its first rendered window. This checks process attachment
without relying on a hidden console window during automated launches.

## Follow-up scope

Store uploads, installers, signed distribution workflows, packed asset archives,
cross-compilation, additional architectures, and macOS follow after the initial
portable Windows/Linux packages. They do not block the first publishing command.
