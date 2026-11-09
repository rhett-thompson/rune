# My Rune game

This is an independent game project. It requires the Odin compiler and a Rune
engine checkout; the engine does not need to be copied into this folder.

From this directory, build and run on Windows:

```bat
build.bat --rune-root ../rune --run
```

On Linux:

```sh
sh build.sh --rune-root ../rune --run
```

The helpers use native OS tools with no additional scripting runtime. The output
is `build/game.exe` on Windows and `build/game` on Linux. Replace `../rune` with
the path to your engine checkout. Quote paths containing spaces. Alternatively,
set `RUNE_ROOT` once in your shell and omit `--rune-root`.

The scripts build into `build/`. The generated `rune.init_project()` entry point
finds `project.json` in the parent of the executable's `build/` directory, so you
can launch a development executable from any working directory. Pass `--release`
for an optimized (`-o:speed`) development build, including when measuring
performance. Runtime checks remain enabled; hot reload is controlled separately
by `project.json`.

For a player executable, use `build.bat --rune-root ../rune --player` on Windows
or `sh build.sh --rune-root ../rune --player` on Linux. This enables optimization,
sets `RUNE_PLAYER=true`, and selects static raylib. The player profile disables
developer console/inbox access, hot reload, gizmos, and FPS overlays. Error
reporting remains available. Build on the target operating system.

For a distributable package, edit `publish.json` and run the engine's publisher:

```bat
..\rune\tools\publish.bat --project .
```

```sh
sh ../rune/tools/publish.sh --project .
```

Adapt the engine path as needed. Publishing builds optimized player code, copies
the selected content and required notices, validates the package, audits native
dependencies, and creates a fresh folder plus ZIP/tar.gz under `build/publish/`
by default. Set `output_directory` in `publish.json` to change the parent
directory relative to the game root. Use `--output <new-directory>` to override
the full package directory for one run. Existing outputs are
never replaced. Each target builds on its matching OS; the Linux glibc ceiling
defaults to 2.39 and requires a compatible SDK/build environment. Windows copies
required app-local CRT dependencies from an official installed Visual Studio
redist directory when available. See Rune's `docs/publishing.md` for overrides
and the full config/command reference.

The publisher includes `project.json` and `assets.json` and follows the startup
scene, input mappings, and known resource references. Add other runtime files,
such as code-loaded scenes, under `assets` in `assets.json`. Use `directories`
for whole trees the game needs at runtime. Paths remain game-relative. List asset
licenses and credits under `licenses` in `publish.json`. Additional compiler
collections and defines also belong in `publish.json`. The publisher supplies
Rune and r3d automatically. Use `--dry-run` to validate the package plan.

A packaged player looks for `project.json` beside itself and launches from any
working directory. You can also stage a `--player` executable manually:

```text
MyGame/
  game.exe                 (game on Linux)
  project.json
  assets.json
  scenes/main.scene.json
  input/default.input.json
```

Include any additional asset folders and files your game uses in the same layout.
`--player --run` is rejected because the build output does not contain the game
content. Static raylib alone does not establish that a Linux package has every
required system library; check native dependencies before distributing it.

The initial scene is empty. Add gameplay in `main.odin`, scene data in
`scenes/main.scene.json`, and action bindings in `input/default.input.json`.
Rune watches the active scene for saved changes automatically.

For automated inspection, enable the console inbox. Pass game arguments after `--`:

```bat
build.bat --rune-root ../rune --run -- --console-dir=build/console
```

```sh
sh build.sh --rune-root ../rune --run -- --console-dir=build/console
```

Then use your engine checkout's `.\tools\console.bat` or `sh tools/console.sh` to
send `status`, `inspect`, `step`, or `capture` commands. See the engine's
`docs/runtime-console.md` for the command reference.

The `schemas/` directory created by the project helper is a local copy of Rune's
JSON schemas. It supports editing without a network connection. Copy updated
schemas from the engine when upgrading Rune.
