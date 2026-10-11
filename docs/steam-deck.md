# Steam Deck examples

Rune supplies controller bindings, a controller-operated launcher, and a Linux
staging helper. The staging tree contains all 39 examples listed in
`examples/examples.json`, their resources, native library notices, and the launcher.
Odin, Python, Git, and the R3D source checkout are build-machine dependencies;
they are not needed to run the staged examples. Linux graphics/audio system
libraries and a working desktop session are still required.

## Build the staging tree

Build on Linux AMD64 with the pinned Odin release and the dependencies in
[Linux development](linux.md). Ubuntu 24.04 provides a glibc 2.39 build baseline.
A newer host can produce binaries requiring newer symbols, even when all Rune
libraries are static. Build inside an appropriate
[Steam Linux Runtime SDK](https://github.com/ValveSoftware/steam-runtime)
or supply a compatible compiler/linker sysroot explicitly.

```sh
sh tools/stage_deck.sh --destination build/deck-stage --jobs 4
```

For a separate toolchain:

```sh
sh tools/stage_deck.sh --odin /path/to/odin \
  --extra-linker-flags '--sysroot=/path/to/compatible-sysroot' \
  --destination build/deck-stage
```

The script builds optimized Linux binaries with `RAYLIB_SHARED=false`, parses the
manifest as JSON, and audits every binary with `readelf`. It rejects requirements
above `GLIBC_2.39` and shared Rune native libraries. It records the maximum glibc
version and remaining system libraries in `glibc-audit.json`. This is an ABI gate,
not a substitute for testing those libraries and rendering on the target device.
The helper uses the selected build environment's libc; it does not download,
replace, or bundle glibc.

`--jobs` selects a positive number of concurrent builds (default 1). Reduce it
on machines with limited memory. Packaging starts after every build finishes;
any build failure prevents resource copying and the final audit.

The destination must be new, preventing stale binaries from entering a package.
An interrupted build leaves its partial directory for inspection. To audit a
previously completed tree again:

```sh
sh tools/stage_deck.sh --destination build/deck-stage --audit-only
```

Rehearse from the staging tree in a Linux desktop session:

```sh
cd build/deck-stage
./run.sh
```

`run.sh` resolves its own directory and sets `RUNE_EXAMPLES_PREBUILT=1`, leaving
the ordinary `PATH` available to system tools. The launcher runs `build/<example>`
directly. D-pad or left stick moves through examples and categories; A launches
the selection and B closes the launcher. Hold START for one second to close a
Rune example and return to the launcher. Example READMEs list their controls and
any interactions that still need a mouse or keyboard.

## Upload to a Deck

Follow Valve's current
[loading and running games guide](https://partner.steamgames.com/doc/steamhardware/loadgames)
to pair the SteamOS Devkit Client with your device. In Title Upload use:

| Setting | Value |
| --- | --- |
| Local Folder | The complete `build/deck-stage` directory |
| Start Command | `./run.sh` |
| Name | `Rune Examples` |

Use a gamepad Steam Input layout so the application receives normal gamepad
buttons and axes. The controls use Xbox-style logical button names; the device's
physical labels can differ. Do not infer physical controller behavior from a
connected-device name alone.

## Console diagnostics

The runner forwards `--console-dir=console` to each example through
`RUNE_EXAMPLE_ARGS`. From a terminal in the uploaded tree, while an example runs:

```sh
./console.sh --command pads --json
./console.sh --command status --json
./console.sh --command 'capture build/deck-frame.png' --json
./console.sh --command quit --json
```

Each example runs in the staging root, so the inbox's relative path remains
consistent. `RUNE_EXAMPLE_ARGS` also forwards your extra flags. Its parser supports
single or double quotes for spaces and backslash escapes; it performs no shell
expansion or command substitution:

```sh
RUNE_EXAMPLE_ARGS='--some-option="two words"' ./run.sh
```

## Device verification

Local checks on 2026-10-11 used Ubuntu 24.04.2 under WSL2, glibc 2.39, and pinned
Odin `dev-2026-10-nightly:84bc3fc` with HEAD `bffb14a` plus the current working
changes. All 39 optimized static examples and the launcher built; every binary's
maximum requirement was `GLIBC_2.38`. All 40 resolved their system libraries
without the isolated build environment. The full headless Linux validation suite
and a separate hidden Clay UI runtime check through WSLg also passed; see
[Linux verification status](linux.md#verification-status). Runner and console wrapper fixtures
passed from a path containing spaces with Odin absent from `PATH`; these checks
used executable stubs and did not exercise controller hardware or rendering.

No Steam Deck or physical-controller test has been performed for these changes.
Before claiming device support, record SteamOS/runtime version, controller/layout,
graphics driver, compiler, and source revision, then check:

1. The staging tree starts without Odin on the device.
2. D-pad and stick navigation, launch, return, and launcher exit work.
3. `pads` reports live axes in the active Steam Input layout; example actions
   confirm the buttons.
4. Every example loads its resources and input mappings.
5. Jump, trigger actions, free look, orbit, and zoom work in their examples.
6. Both multiplayer pads control their own player; tanks retain turret aim.
7. Holding START closes examples; taps preserve normal Start actions.
8. Save/load/rebinding preserve controller mappings and schema pointers.
9. Audio, resize/fullscreen, focus loss, and rendering are acceptable.
10. The console can report status, capture a frame, and close an example.

This tree is for local testing. Preserve `THIRD_PARTY.md` and the supplied notices;
that document records example assets whose distribution provenance is still open.
