# Rune Publish

Rune Publish is the standalone command-line application for building a Rune
game's `publish.json` into a portable player package. It builds optimized player
code, stages selected content and notices, validates references and native
dependencies, and produces a new package directory plus a Windows ZIP or Linux
tar.gz. Existing outputs are never replaced.

## Run through the compatibility launchers

From a game directory, adapt the engine path:

```bat
..\rune\tools\publish.bat --project .
```

```sh
sh ../rune/tools/publish.sh --project .
```

The launchers build this application in an isolated temporary directory through
Rune's compiler lock, supply `--rune-root`, and forward the remaining arguments.
They require Odin on `PATH`. The tool's game compilation uses the same lock.

Add `--dry-run` to validate content and preview pruning without compiling the
game or writing a package. The launcher still compiles Rune Publish itself.

## Build and run the executable

Run these commands from the Rune checkout. Use the compiler version recorded in
[`toolchain.json`](../toolchain.json).

Windows PowerShell:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
.\tools\odin.bat build rune_publish -collection:rune=rune -linker:msvc -out:build/rune_publish.exe
.\build\rune_publish.exe --rune-root . --project ../MyGame
```

Linux:

```sh
mkdir -p build
sh tools/odin.sh build rune_publish -collection:rune=rune -out:build/rune_publish
./build/rune_publish --rune-root . --project ../MyGame
```

These wrappers serialize compilation. The built executable can run from any
working directory; pass `--rune-root` or set `RUNE_ROOT` to locate the engine.
Relative command-line paths resolve from the caller's working directory.

## Options

```text
rune_publish [options]
```

| Option | Behavior |
| --- | --- |
| `--project DIRECTORY` | Game directory containing `publish.json`; defaults to `.`. |
| `--output DIRECTORY` | New package directory; defaults to `GAME_ROOT/build/publish/<id>-<version>-<target>`. The adjacent archive must also be absent. |
| `--target windows-amd64\|linux-amd64` | Defaults to the current host target; must be enabled in `publish.json` and match the host OS. |
| `--rune-root DIRECTORY` | Rune checkout; defaults to `RUNE_ROOT`. Supplied automatically by the compatibility launchers. |
| `--odin COMPILER` | Game compiler; defaults to `ODIN` or `odin`. Must match the release in `toolchain.json`. This does not select the launcher's bootstrap compiler. |
| `--glibc-max VERSION` | Linux symbol-version ceiling; defaults to `2.39`. |
| `--windows-runtime-directory DIRECTORY` | Override discovery with an official installed AMD64 VC CRT directory. |
| `--windows-runtime-license FILE` | Optional redistributable notice override on Windows. |
| `--dry-run` | Validate content dependencies and report pruning totals without compiling the game or writing a package. |
| `--help`, `-h` | Print usage without publishing. |

Exit codes are `0` for successful publication, dry run, or help; `1` for a
publishing failure; and `2` for invalid command-line options. Launcher bootstrap
failures return nonzero before the application runs.

## Configuration and limits

The game's `publish.json` supplies package identity, enabled targets, explicit
content and licenses, custom build settings, and optional asset pruning. See
the [publishing guide](../docs/publishing.md#publishing-configuration-and-build)
and [schema](../schemas/publish.schema.json) for the full contract. Pruning
requires explicit roots or dependency manifests for resources loaded dynamically
by game code; it never deletes source assets.

Generated games include an empty `publish.assets.json` registered under
`publish.json`'s `prune.manifests`, with pruning disabled by default. Add
code-loaded resources to its `roots` and keep those paths covered by `content`.
Set `prune.enabled` to true to use pruning. When disabled, dependency manifests
and their input hashes are not checked, including during a dry run.

Publishing supports native Windows AMD64 and Linux AMD64 builds. Windows needs
MSVC and an official installed AMD64 VC CRT when required by the linked native
libraries. Linux needs `flock`, `readelf`, `mktemp`, and `tar`; build with an SDK
or sysroot compatible with the selected glibc ceiling. The output filesystem
must support atomic no-replacement renames; use native Linux storage if a WSL
Windows mount rejects them.

Failed builds preserve their staging directory for inspection. A failure during
the final pair of moves can leave the completed package with its archive still
in staging. Dry runs do not audit a compiled executable's native imports.
Extract and relocate the resulting package, then exercise the game's runtime
behavior before distributing it. Current verification context and remaining
platform limits are recorded in the [publishing guide](../docs/publishing.md).

Store uploads, installers, signing, packed asset archives, cross-compilation,
additional architectures, and macOS are outside the current tool's scope.

## Focused tests

From the Rune checkout on Windows:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
.\tools\odin.bat test rune_publish -collection:rune=rune -define:ODIN_TEST_THREADS=1 -linker:msvc -out:build/rune_publish_test.exe
```

On Linux:

```sh
mkdir -p build
sh tools/odin.sh test rune_publish -collection:rune=rune -define:ODIN_TEST_THREADS=1 -out:build/rune_publish_test
```

The repository's `tools/validate.bat` and `tools/validate.sh` also build and test
this application. These focused checks cover configuration, content, pruning,
native audit, command construction, and finalization; full relocated game
qualification follows the [acceptance checks](../docs/publishing.md#acceptance-checks).
