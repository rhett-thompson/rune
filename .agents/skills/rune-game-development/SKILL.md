---
name: rune-game-development
description: "Build or modify games using Rune, the Odin game engine. Use for creating Rune game projects, authoring scenes and components, implementing gameplay/input, and integrating rendering, UI, or audio through Rune's APIs."
---

# Rune Game Development

Use this skill for game development with Rune. The separate `rune-bug-triage`
skill covers engine regressions and dependency investigation when those become
relevant; it is not required for ordinary game work.

## Locate the game and engine

Identify the game directory containing `project.json` (`GAME_ROOT`) separately
from the Rune checkout containing `rune/core/core.odin` (`RUNE_ROOT`). Use the
user's paths, existing build helpers, `--rune-root`, or `RUNE_ROOT` environment
variable to resolve them; do not assume an installed skill is beside the engine.
Read each root's applicable agent instructions. Paths in these notes are relative
to `RUNE_ROOT` unless explicitly marked `GAME_ROOT`.

Read only the references needed for the task:

| Task | Reference |
| --- | --- |
| New/existing project, build helpers, dependencies, asset paths, validation, console inspection | [project-workflow.md](references/project-workflow.md) |
| Scene/prefab JSON, typed ECS, systems, controller input/rebinding, reload/save state | [gameplay-and-scenes.md](references/gameplay-and-scenes.md) |
| 2D/3D rendering, transforms/collision, canvas/picking, Clay UI, audio ownership | [rendering-ui-audio.md](references/rendering-ui-audio.md) |
| Navigation, networking, generated geometry, memory, pools/tweens | [subsystems-and-ownership.md](references/subsystems-and-ownership.md) |

Use Rune's current `docs/components.md`, schemas, focused guides, and the closest
working example for API details. Do not load the entire manual or all examples
for a small feature. Check installed source signatures before inventing calls.

## Implement through Rune's supported workflow

- For a new standalone game, use Rune's project generator in the requested
  location. Preserve an existing game's structure. Learn from examples in place:
  they can depend on neighboring assets and helpers and are not standalone game
  templates.
- Generated games use `rune.init_project()` for executable-relative startup:
  development binaries in `build/` use the parent project's JSON; player binaries
  use adjacent JSON/content. `--player` is a distinct runtime profile from
  optimized `--release`. Use `engine.project_directory` for optional renderer
  roots and `rune.resource_path` for custom file reads; keep writes in user-data
  storage. See the project workflow for staging and migration limits.
- Publish standalone games with the `rune_publish/` command-line application,
  using `tools/publish.bat` or `tools/publish.sh` and the game's `publish.json`.
  See `rune_publish/README.md` for direct builds and CLI options.
  Include resource folders and explicit game notices;
  opt-in `prune` follows known references plus explicit roots/manifests for
  code-loaded/custom data. Keep generated manifests current with input hashes
  and preview with `--dry-run`. Custom compiler requirements belong in that config. Publishing
  validates staged references and native dependencies before producing a fresh
  folder/archive. Check the documented host/ABI/runtime requirements and test
  the extracted game; a successful archive alone does not prove compatibility.
- When adding, changing, or removing game code that loads assets, scenes,
  prefabs, or custom data, update the game's publishing dependency manifest in
  the same change, including when pruning is currently disabled. Declare
  runtime-selected files or their complete directory trees; Rune does not scan
  Odin source. Reuse the game's existing manifest or generator.
  New games register an empty `publish.assets.json`; populate its `roots` while
  preserving the game's opt-in pruning setting. See
  [code-loaded resources](references/project-workflow.md#declare-code-loaded-resources)
  for manifest creation, registration, and validation.
- Prefer the engine-owned startup scene and registered `rune.System` callbacks.
  Register custom component types before loading scenes that use them. Choose
  callback timing from the lifecycle reference rather than manually advancing
  physics, audio, particles, or animation that the scene loop already owns.
- The standalone navmesh baker omits unregistered game components and warns for
  each omission; review those warnings for misspelled built-ins. Normal scene
  loading stays strict. Bake a game-side World when systems generate geometry;
  see `docs/navigation-3d.md`.
- Author scene/prefab/input JSON against the game's schemas. Verify omitted-field
  defaults with Rune's decoder/default helpers. Use typed ECS setters/adders and
  supported named-instance APIs so validation, ownership, change tracking, and
  physics/render caches stay consistent.
- Treat authored scene documents as the source of truth. Game level editors own
  creating and saving them; Rune owns validation, loading, and instantiation.
  Keep scene saving in game-owned tools and scene export APIs/console commands
  out of the engine. Runtime Worlds are instances of authored data; component
  serialization and checkpoint saves do not replace that source. See the scene
  authoring boundary in `README.md` and the gameplay/scenes reference.
- Keep ordinary asset paths project-relative; use the documented `prefab://`
  prefix when reusable component assets should resolve from their authoring
  file. Match drawing and picking coordinates to the game canvas or native UI
  as appropriate. Use Rune's camera helper for custom Camera2D drawing;
  initialize and dispose optional UI/3D resources at the appropriate system
  lifecycle boundaries.
- Use `ecs.OrbitCamera3D` for reusable 3D orbit navigation. Tool viewports can
  supply resolved input from `ui_update` for navigation while paused; the host
  owns focus and drag capture. Keep framing targets and level interpretation in
  the game. See [orbit navigation](references/rendering-ui-audio.md#orbit-navigation-in-tool-viewports)
  for pan/zoom modes and input timing.
- Use asset-manager material previews for live material authoring; they update
  existing renderer caches without changing files. Clone borrowed material data,
  save JSON through the tool, and clear previews when live authoring ends. See
  the rendering reference for ownership and save ordering.
- Fade installed runtime geometry with `ecs.set_static_mesh_opacity`; it changes
  per-draw material alpha without replacing geometry or changing collision.
  Games own timing and cleanup; mesh replacement resets opacity to one. See
  the subsystem reference and `docs/static-geometry.md` for blend behavior.
- Reacquire scene entities and borrowed state after reload or restoration.
  Frame scratch and borrowed component strings/collections are not persistent
  game storage. Keep durable game state in owned storage or configured saves.
- Use the built-in console for runtime inspection; Tab/Shift+Tab cycles matching
  command names and supported arguments, including entity IDs and component
  names. Suggestions appear above the input with the current match highlighted.
  Up/Down selects a suggestion without editing; Enter accepts it, then another
  Enter executes. Clicking any visible suggestion also accepts it and hides the
  list; Enter then executes. Ctrl+Up/Down always browses command history.
  With the console open, left-click a scene object outside the panel to print
  its hierarchy and current component values; supported picking uses active
  scene cameras and cached geometry without changing the command draft. Amber
  corner brackets follow the selected object's rendered bounds in a separate
  native debug overlay; closing the console or clicking empty canvas clears it.
  Refer to the current selection with `@picked` in engine entity arguments;
  component and field completion follows it, including while it is disabled.
  `disable @picked` hides its brackets but keeps the alias valid for
  `enable @picked`. Console focus temporarily releases
  and shows the mouse, then restores the desired gameplay mode. Use
  `rune.set_cursor_mode` for visible, hidden-free, or captured gameplay cursors.
  For controller use, opt in with `rune.set_gamepad_cursor_auto_hide(game, true)`:
  gamepad activity hides a free pointer, and mouse use reveals it across menus
  and the console without changing gameplay capture. See `docs/gamepads.md`.
  Keep `rune.shutdown` in normal cleanup; it releases capture and shows the cursor
  before hiding and destroying the window, without system pointer-counter hacks.
  Custom commands can supply read-only argument completion callbacks. See
  [console inspection](references/project-workflow.md#inspect-gameplay-through-the-console)
  for interactive use and the local command inbox.
- Use the console helpers' `--batch-file` for ordered inspection sequences.
  Commands advance one per frame and wait for deferred completion; inspect the
  batch's `complete`, `ok`, and per-entry `data`. Compare deterministic component
  values in controlled paused runs, since frame counters and timing output can
  differ from separate requests. A timeout does not cancel a claimed batch;
  inspect its outcome before retrying side effects. See the console inspection
  reference for file limits, result ownership, and custom-loop cleanup.
- Use `step --fast [count]` for controlled paused simulation checks that can
  group up to eight complete ticks per rendered frame. Update systems still run
  per tick; UI, input polling, audio, and drawing remain per frame. Frame-driven
  game logic and raw raylib input can differ from normal stepping. Fast stepping
  temporarily removes only the software cap and restores the latest runtime
  setting. See the console inspection and lifecycle references for input edges,
  deterministic comparisons, and custom-loop cleanup.
- For console-driven runs, project `window.hidden: true` keeps initialization
  and engine-owned loops hidden. Use `rune.set_window_hidden` or `window hidden`
  / `window show` for runtime visibility; `show_window` remains a startup helper.
  Reveal and settle any mode transition before `capture`, which rejects hidden
  windows with `data.error: "capture_window_hidden"`. A graphics context/display
  is still required, and hiding does not isolate physical gamepad input. See
  the project workflow and `docs/display.md` for mode and pacing contracts.

## Verify the game, then report the result

Run project-file validation when authoring data, build the actual game with the
appropriate compiler/collections, and exercise the affected behavior when the
environment supports it. A successful build does not prove gameplay, visual
alignment, or audible output. Choose focused tests for game logic; an ordinary
game feature does not require a full Rune release check.

Give the user the game location, exact build/run instructions, what works, and
any runtime checks still unverified. Keep gameplay changes in the game project;
identify genuine engine/API gaps rather than silently changing unrelated engine
defaults or replacing the user's chosen framework.

## Keep the skill current

The canonical package is `RUNE_ROOT/.agents/skills/rune-game-development/`.
Follow `RUNE_ROOT/AGENTS.md` when changes affect these workflows or contracts,
and synchronize a corresponding installed personal copy when present. Keep
these notes portable, link maintained sources, and retire outdated advice.
