# Rune Publish

Rune Publish is the standalone command-line application for packaging Rune games.
It builds optimized player code, stages selected content and notices, validates
references and native dependencies, and produces a new package directory plus a
Windows ZIP or Linux tar.gz. Existing outputs are never replaced.

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

Add `--dry-run` to validate the package plan without compiling the game or
writing a package. The launcher still compiles Rune Publish itself.

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
| `--project DIRECTORY` | Game directory containing `publish.json`, `project.json`, and `assets.json`. Defaults to `.`. |
| `--output DIRECTORY` | Overrides the full path to the new package directory. Relative paths resolve from the caller's working directory. The adjacent archive must also be absent. |
| `--target windows-amd64\|linux-amd64` | Defaults to the current host target; must be enabled in `publish.json` and match the host OS. |
| `--rune-root DIRECTORY` | Rune checkout; defaults to `RUNE_ROOT`. Supplied automatically by the compatibility launchers. |
| `--odin COMPILER` | Game compiler; defaults to `ODIN` or `odin`. Must match the release in `toolchain.json`. This does not select the launcher's bootstrap compiler. |
| `--glibc-max VERSION` | Linux symbol-version ceiling; defaults to `2.39`. |
| `--windows-runtime-directory DIRECTORY` | Override discovery with an official installed AMD64 VC CRT directory. |
| `--windows-runtime-license FILE` | Optional redistributable notice override on Windows. |
| `--dry-run` | Validate the package plan without compiling the game or writing a package. |
| `--help`, `-h` | Print usage without publishing. |

Exit codes are `0` for successful publication, dry run, or help; `1` for a
publishing failure; and `2` for invalid command-line options. Launcher bootstrap
failures return nonzero before the application runs.

## Configuration and limits

The game's `publish.json` supplies package identity, enabled targets, licenses,
and custom build settings. Its optional `output_directory` sets the parent
directory for the versioned package folder and adjacent archive, relative to the
game root. The parent defaults to `build/publish`. A CLI `--output` replaces
the entire package path.

The publisher requires `project.json` and `assets.json`
at the game root and includes both in the package. It follows the startup scene,
input mappings, and recognized resource references. Register other runtime files
under `assets` and complete resource trees under `directories` in the catalog.
Declare custom dependencies when a selected file refers to other resources
through a game-defined format.

Game code can open the same catalog through [`rune:assetcatalog`](../docs/assetcatalog.md).
Authored resource fields still use ordinary paths. See the [publishing guide](../docs/publishing.md#publishing-configuration-and-build)
and [schema](../schemas/publish.schema.json) for the full contract.

Publishing supports native Windows AMD64 and Linux AMD64 builds. Windows needs
MSVC and an official installed AMD64 VC CRT when required by the linked native
libraries. The publisher selects MSVC through `tools/find_msvc.bat` and looks for
the CRT in `VCToolsRedistDir` or the installed Visual Studio redist trees.
Linux needs `flock`, `readelf`, `mktemp`, and `tar`. Build with an SDK
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
this application. These focused checks cover configuration, dependency selection,
native audit, command construction, and finalization; full relocated game
qualification follows the [acceptance checks](../docs/publishing.md#acceptance-checks).
