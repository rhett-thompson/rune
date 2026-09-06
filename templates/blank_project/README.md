# My Rune game

This is an independent game project. It requires the Odin compiler and a Rune
engine checkout; the engine does not need to be copied into this folder.

From this directory, build and run with PowerShell 7 on Windows or Linux:

```powershell
./build.ps1 -RuneRoot ../rune -Run
```

From Bash, use `pwsh -NoProfile -File build.ps1 -RuneRoot ../rune -Run`.
PowerShell is needed for the helper scripts, not for the resulting game.
The output is `build/game.exe` on Windows and `build/game` on Linux.

Replace `../rune` with the path to your engine checkout. Paths containing spaces
work. Alternatively, set `RUNE_ROOT` once in your shell and run `./build.ps1 -Run`.
The script builds into `build/` and runs with this project as the working directory.
When launching the executable yourself, run it from this directory.

Use `./build.ps1 -RuneRoot ../rune -Release` for an optimized (`-o:speed`)
build, including when measuring performance. This keeps runtime checks enabled;
hot reload is controlled separately by `project.json`.

The initial scene is empty. Add gameplay in `main.odin`, scene data in
`scenes/main.scene.json`, and action bindings in `input/default.input.json`.
Rune watches the active scene for saved changes automatically.

For automated inspection, enable the console inbox:

```powershell
./build.ps1 -RuneRoot ../rune -Run -GameArguments '--console-dir=build/console'
```

Then use your engine checkout's `tools/console.ps1` to send `status`, `inspect`,
`step`, or `capture` commands. See the engine's AGENTS.md for the command reference.

The `schemas/` directory created by `new_project.ps1` is a local copy of Rune's
JSON schemas. It supports editing without a network connection. Copy updated
schemas from the engine when upgrading Rune.
