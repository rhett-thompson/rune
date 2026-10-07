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

The scripts build into `build/` and run with this project as the working directory.
When launching the executable yourself, run it from this directory. Pass `--release`
for an optimized (`-o:speed`) build, including when measuring performance. Runtime
checks remain enabled; hot reload is controlled separately by `project.json`.

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
