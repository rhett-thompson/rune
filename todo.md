# Rune Engine — To-Do List

> Planning checklist from our October 7, 2026 discussions. Implementation details and current behavior should be reverified against the latest Rune and dependency source before changes.

> Progress notes below record verified implementation or source review. Items remain open while their stated acceptance checks are pending.

## Rendering and graphics

- [ ] **Investigate cascaded shadow maps (CSM).** Check current R3D support and options for improving directional-light shadow detail across large outdoor scenes; prototype or assess renderer modifications if necessary.
- [ ] **Investigate shadow disabling/state synchronization.** Reproduce the suspected issue where turning off shadows on an existing light may not clear the corresponding R3D shadow state; fix and regression-test if confirmed.
- [ ] **Review shadow defaults.** Decide whether newly created lights should cast shadows by default and document the tradeoffs.
- [ ] **Fix V-Sync and frame limiting.** Provide genuine display-synchronized V-Sync and an independent, configurable frame-rate cap. Test frame pacing and tearing on 60 Hz and high-refresh-rate displays.
  - October 7: implemented raylib V-Sync requests, independent `window.target_fps` (0 means uncapped), and runtime setters. Startup/reinitialization and window-mode transitions preserve the requested settings. The full Windows validation suite passes (96 builds and 40 project checks), as do settings, native frame-limiter, and window-mode runtime checks. Visible pacing/tearing checks on both display classes remain pending. Linux verification is pending because the installed toolchain lacks native Linux stb/Box2D libraries. See [display settings](docs/display.md).
- [x] **Upgrade R3D.** Evaluate a newer compatible R3D release versus the pinned revision; update Odin bindings and build integration as needed. Rebuild/test the model importer and regression-test materials, lighting, shadows, post-processing, and examples.
  - October 7: migrated to the official [v0.11.0 prerelease](https://github.com/Bigfoot71/r3d-odin/releases/tag/v0.11.0). Rune uses the new light APIs and converts native shadow seconds while preserving public `interval_ms`. Added reproducible [binding corrections](third_party/r3d-compat/README.md), keeping the upstream gitlink; launchers, validation, project builds, and release exports prepare them automatically. Ported the FBX/animation importer and rebuilt Windows/Linux archives. A clean Windows export passes 96 builds, 40 project checks, and 24 runtime validators covering materials, lighting, shadows, animation, post-processing, and other engine systems. Its independent starter project passes debug/optimized builds and console pause/step/capture checks. All 274 checked ABI sizes, alignments, and field offsets match. Native Ubuntu preparation and shell checks pass; Linux compiler/renderer runtime acceptance remains pending in [Linux verification status](docs/linux.md#verification-status).

## Toolchain and engine runtime

- [ ] **Upgrade Odin.** Evaluate the October 2026 Odin toolchain (`dev-2026-10`), adjust build scripts and dependencies as needed, and compile/test all examples and third-party bindings before standardizing on it.
  - October 7: upgraded the repository pin and archive checksums to [dev-2026-10](https://github.com/odin-lang/Odin/releases/tag/dev-2026-10), tested as `dev-2026-10-nightly:84bc3fc` on Windows AMD64. The default RAD linker could not link bundled zlib `/GL` objects and crashed on Clay UI/window builds; Windows helpers, launcher child builds, and documented commands now select `-linker:msvc`. The full suite passes: 96 builds, 40 project checks, and 25 runtime validators. Optimized physics, third-person 3D, and template builds also pass, as does launcher compilation. Previously generated projects need the flag added to their copied `build.bat`. Linux acceptance remains open: neither current WSL distro has a Linux Odin installation/native vendor libraries; historical baseline failures remain recorded in [Linux verification status](docs/linux.md#verification-status).
- [ ] **Support headless Rune execution.** Allow ECS, scene loading, simulation, physics, and fixed-step updates without initializing a graphical window, GPU renderer, or (where unnecessary) audio. Add a build/CLI option, a minimal headless example, and Windows/Linux tests.

## Multiplayer

- [ ] **Prototype host-authoritative multiplayer with a lightweight relay.** Build an optional standalone relay executable that forwards traffic without simulating the game. Add session/peer networking APIs and basic networked entity/component replication; demonstrate a two-player example. Keep database dependencies optional/not required for the initial relay. Consider third-party relay providers as alternatives; leave full dedicated authoritative servers for a later phase.

## Terrain

- [ ] **Expand the terrain system.** Add seamless adjacent tiles, distance-based LOD, and streaming/loading/unloading near the player. Explore incremental or asynchronous terrain rebuilds to avoid heightmap-edit hitches. Consider terrain sculpting and material-painting tools as follow-on work.

## Animation and tweening

- [ ] **Extend Rune's generic tween utility with sequencing/chaining.** Support a fluent, code-first API for ordered tweens, delays, callbacks/events, and optional parallel steps, with predictable cancellation/interruption behavior.
- [ ] **Connect animation playback and crossfades to tween-like sequencing.** Enable event-driven chains such as play/crossfade → wait → callback/next animation without requiring a Unity-style animator node graph. Build on existing animation and crossfade functionality rather than replacing it.

## Documentation and repository presentation

- [ ] **Create comprehensive, organized Rune documentation.** Cover installation/getting started, engine architecture and lifecycle, ECS and systems, scenes and prefabs, all built-in components (properties, defaults, examples), public Odin APIs, rendering, physics, input, audio, navigation, animation, and working tutorials. Prefer Markdown close to the source, a searchable documentation site, and generated/indexed API references where feasible.
- [ ] **Document the debug-console screenshot command.** Explain opening the console with backtick, using `capture` (including an optional filename), and locating the saved image in `build/captures`; verify behavior/paths before publishing documentation.
- [ ] **Add images to the GitHub repository homepage/README.** Capture and curate a hero screenshot or short GIF plus a small gallery showing meaningful engine features and example scenes; add descriptive alt text and keep assets reasonably sized.

## Possible follow-on investigations (discussed, not yet committed as primary tasks)

- [ ] Evaluate R3D volumetric fog/god rays, reflection probes, instancing, and better examples for SSGI/SSR/auto-exposure after the R3D upgrade.
- [ ] Evaluate FSR 1 spatial upscaling; revisit TAA or temporal upscaling only if deeper rendering-pipeline work is justified.
- [ ] Investigate optional baked lightmap workflows for static modular geometry.
