# AGENTS.md

## Project Context

This repository is for a lightweight game engine written in Odin, built on top of raylib.

The engine should support a code-first workflow while also allowing game data to be defined in JSON files. JSON files should describe scenes, entities, components, prefabs, assets, project settings, input mappings, and editor metadata.

The engine may eventually include an optional editor similar in spirit to Unity, where users can visually manipulate scenes, entities, components, and assets. However, the editor must not be required. The project should remain fully usable from code and editable by hand through JSON files.

The guiding idea:

> A code-first Odin/raylib engine where JSON is the asset, scene, prefab, and project format, and the editor is simply a visual manipulator of those files.

Do not attempt to build a full Unity clone. Build a lightweight, data-driven engine/framework that sits between raw raylib and a full editor-first game engine.

---

## Core Principles

1. Code-first must always work.
   - A developer should be able to make a complete game using Odin code plus JSON files.
   - The editor is optional.

2. JSON should be declarative.
   - JSON describes data, not behavior.
   - Gameplay behavior belongs in Odin systems/components.
   - Do not add eval-like scripting to JSON.

3. The editor should not own the project.
   - A project should just be a folder of readable files.
   - JSON files should remain hand-editable.
   - The editor should load, modify, validate, and save the same files used by the runtime.

4. raylib handles low-level functionality.
   - Windowing
   - Input
   - Graphics
   - Textures
   - Models
   - Audio
   - Shaders

5. The engine owns higher-level game concepts.
   - Project loading
   - Scene loading
   - Entity/component system
   - Prefabs
   - Asset registry
   - Input actions
   - Hot reload
   - Debug tools
   - Optional editor integration

6. Start small and practical.
   - The first goal is to make it faster and cleaner to build a small game than writing raw raylib every time.
   - Avoid large-editor-first design.

---

## Preferred Initial Repository Structure

```txt
/
  AGENTS.md
  README.md

  rune/
    core/
    ecs/
    assets/
    scene/
    prefab/
    input/
    render/
    physics/
    audio/
    editor_bridge/

  editor/
    # optional later

  examples/
    hello_scene/
    platformer_2d/
    first_person_3d/

  tools/
    asset_compiler/
    project_validator/

  third_party/
    raylib/
```

Example game project structure:

```txt
MyGame/
  project.json

  assets/
    textures/
    audio/
    models/
    fonts/
    shaders/

  scenes/
    main.scene.json
    menu.scene.json

  prefabs/
    player.prefab.json
    enemy.prefab.json

  input/
    default.input.json

  scripts/
    player.odin
    enemy_ai.odin

  build/
```

---

## Example `project.json`

```json
{
  "name": "MyGame",
  "startup_scene": "scenes/main.scene.json",
  "window": {
    "width": 1280,
    "height": 720,
    "title": "My Game",
    "fullscreen": false,
    "vsync": true
  },
  "input": "input/default.input.json"
}
```

---

## Example Scene JSON

```json
{
  "name": "Main Scene",
  "entities": [
    {
      "id": "player",
      "name": "Player",
      "components": {
        "Transform": {
          "position": [0, 1, 0],
          "rotation": [0, 0, 0],
          "scale": [1, 1, 1]
        },
        "SpriteRenderer": {
          "texture": "assets/textures/player.png",
          "origin": [0.5, 0.5]
        },
        "PlayerController": {
          "speed": 6.0,
          "jump_force": 12.0
        }
      }
    }
  ]
}
```

---

## Example Prefab JSON

```json
{
  "name": "Enemy",
  "components": {
    "Transform": {
      "position": [0, 0, 0],
      "rotation": [0, 0, 0],
      "scale": [1, 1, 1]
    },
    "SpriteRenderer": {
      "texture": "assets/textures/enemy.png"
    },
    "EnemyAI": {
      "move_speed": 2.5,
      "attack_range": 1.25
    }
  }
}
```

---

## Example Input Mapping JSON

```json
{
  "actions": {
    "move_left": [
      { "type": "keyboard", "key": "A" },
      { "type": "keyboard", "key": "LEFT" }
    ],
    "move_right": [
      { "type": "keyboard", "key": "D" },
      { "type": "keyboard", "key": "RIGHT" }
    ],
    "jump": [
      { "type": "keyboard", "key": "SPACE" },
      { "type": "gamepad_button", "button": "A" }
    ]
  },
  "axes": {
    "move_x": {
      "negative": "move_left",
      "positive": "move_right"
    }
  }
}
```

---

## Runtime Architecture

### Engine Core

Responsibilities:
- Initialize raylib.
- Load `project.json`.
- Create the game window.
- Manage the main loop.
- Track delta time.
- Route update and draw calls.
- Handle shutdown.

Possible API shape:

```odin
main :: proc() {
    engine.init("project.json")

    engine.register_component("PlayerController", PlayerController)
    engine.register_system(player_controller_system)

    engine.load_startup_scene()
    engine.run()
}
```

---

### Entity Component System

Use an ECS-style architecture.

- Entities are lightweight IDs.
- Components are data.
- Systems contain behavior.

Avoid a heavy Unity-style inheritance model.

The scene loader should be able to create components by name using a component registry.

Example conceptual registration:

```odin
register_component("Transform", Transform)
register_component("SpriteRenderer", SpriteRenderer)
register_component("PlayerController", PlayerController)
```

Example scene component block:

```json
"components": {
  "Transform": {},
  "SpriteRenderer": {},
  "PlayerController": {}
}
```

---

### Component Registry

The component registry is critical.

It should map string names to:
- Component type information
- Default values
- JSON serialization logic
- JSON deserialization logic
- Editor-visible fields
- Optional validation logic

Potential metadata per component type:
- Name
- Size
- Deserialize function
- Serialize function
- Inspector metadata
- Default constructor
- Validation function

This allows the editor to display components dynamically without hardcoding every component.

---

### Systems

Systems operate on entities with specific component combinations.

Example:

```odin
player_controller_system :: proc(world: ^World, dt: f32) {
    // Query entities with Transform and PlayerController.
    // Apply input and movement logic.
}
```

Built-in systems may include:
- Transform system
- Sprite rendering system
- Camera system
- Audio system
- Input system
- Collision/physics system
- Animation system

Custom game systems should be written in Odin and registered with the engine.

---

### Scene System

Scenes should be JSON files containing:
- Scene name
- Entities
- Components
- Optional environment settings
- Optional cameras
- Optional editor metadata

Scene loader responsibilities:
- Parse JSON.
- Create entities.
- Create components.
- Resolve asset references.
- Resolve prefab references.
- Set up transform hierarchy.
- Run validation.
- Start scene.

Support initially:
- Loading scenes
- Unloading scenes
- Reloading scenes

Additive scenes can come later.

---

### Prefab System

Prefabs should be reusable entity definitions.

Initial prefab behavior:
- Instantiate a prefab into a scene.
- Allow simple scene-level overrides.
- Save prefab definitions as JSON.

Later:
- Nested prefabs
- Prefab variants
- Better override tracking
- Editor support for apply/revert

Keep the first implementation simple.

---

### Asset Manager

The asset manager should handle:
- Textures
- Fonts
- Sounds
- Music
- Models
- Shaders
- Materials

Responsibilities:
- Load assets by path or asset ID.
- Cache assets.
- Unload unused assets.
- Hot reload changed assets in development.
- Provide missing/fallback assets when load fails.

Asset references in JSON can start as file paths:

```json
{
  "texture": "assets/textures/player.png"
}
```

Add stable asset IDs later only if needed.

---

### Hot Reload

Hot reload should be a first-class feature.

Start with:
- Textures
- Shaders
- Scene JSON
- Prefab JSON
- Material JSON
- Input mapping JSON

Do not start with Odin code hot reload.

Development workflow target:
1. Run the game.
2. Edit a JSON file.
3. Save the file.
4. Running game updates automatically.

Implementation guidance:
- Start with modified-time polling.
- Add platform-specific file watchers later only if needed.

---

### Editor

The editor is optional and should come later.

First editor version should support:
- Open project folder
- View assets
- View scene hierarchy
- Select entity
- Show inspector
- Edit component fields
- Add/remove components
- Move/rotate/scale entities
- Save scene JSON
- Launch game

The editor should be a visual JSON/project manipulator.

Potential editor options:

#### Option A: Odin + raylib + ImGui-style UI

Pros:
- Same language/runtime
- Native feel
- Good game/editor integration

Cons:
- More UI work
- Need immediate-mode UI integration

#### Option B: Local web editor

Pros:
- Easier complex UI
- Good tree/file/inspector panels
- Can run in browser
- Can communicate with running game through WebSocket
- Fits JSON editing well

Cons:
- Adds web stack
- More moving pieces

Possible web editor flow:

```txt
odin-engine-editor.exe
  starts local server
  opens browser
  edits project JSON files
  talks to running game over WebSocket
```

---

## Scripting Decision

Recommended initial choice:

### Odin-only gameplay code

Games should define custom components and systems in Odin.

Avoid adding Lua, Wren, JavaScript, visual scripting, or custom scripting in the MVP.

Possible later scripting options:
- Lua
- Wren
- JavaScript
- Odin dynamic plugin DLLs/shared libraries
- Visual scripting

The first working engine should not depend on a scripting language.

---

## Minimum Viable Product

The MVP should include:

1. Engine initialization
2. raylib window/game loop
3. `project.json` loading
4. Scene JSON loading
5. Entity IDs
6. Built-in `Transform` component
7. Component registry
8. Custom component registration from Odin
9. System registration from Odin
10. `SpriteRenderer` component
11. 2D camera
12. Asset manager for textures
13. Input action mapping
14. Basic prefab loading
15. Hot reload for scene JSON and textures
16. Example game project

The MVP target should be a small playable 2D example, such as:
- top-down movement
- simple platformer
- block breaker
- lane defense prototype
- basic shooter

Preferred first milestone:

> Load a scene from JSON and render a sprite entity on screen through raylib.

---

## Build Order

Use this implementation order unless there is a strong reason not to:

1. Create raw Odin + raylib test program.
2. Wrap raylib initialization and main loop in engine core.
3. Load `project.json`.
4. Add asset manager for textures.
5. Add entity IDs and world storage.
6. Add `Transform` component.
7. Add `SpriteRenderer` component.
8. Add system registration and update/draw pipeline.
9. Add JSON scene loading.
10. Add component registry with JSON deserialization.
11. Add input action mapping.
12. Add prefabs.
13. Add file timestamp-based hot reload.
14. Build first example game.
15. Add basic editor/inspector.
16. Add 3D support.
17. Add asset compiler/build pipeline.

---

## Avoid Early

Do not start with:
- Full Unity-style editor
- Visual scripting
- Custom renderer
- Full terrain system
- Package manager
- Animation graph editor
- Advanced 3D physics
- Networked multiplayer
- Live Odin code reload
- Complex prefab variants
- Complex reflection system
- Supporting every asset type

Do not overbuild before proving the core loop:
1. Define entity in JSON.
2. Load it.
3. Render it.
4. Move it with Odin code.
5. Edit JSON.
6. See changes reload.

---

## Coding Guidance

When implementing code:

- Prefer simple, explicit Odin code.
- Avoid excessive abstraction early.
- Keep modules/packages focused.
- Make data formats readable.
- Add validation and helpful error messages for JSON loading.
- Prefer paths and plain files over hidden project databases.
- Keep runtime/editor concerns separated where practical.
- Use clear names for engine concepts.
- Make examples small and easy to understand.

When making architecture decisions, prefer:
- Data-driven over editor-driven.
- Explicit registration over magic.
- Small working vertical slices over broad incomplete systems.
- JSON-first authoring with the option for binary compiled assets later.
- Code-first gameplay over scripting.

---

## Testing / Validation Expectations

### Platform support

- Windows AMD64 and Linux AMD64 are equal development and release targets.
- Keep project creation, builds, validation, release checks, and console tooling
  usable on both. PowerShell 7 is an accepted cross-platform tooling dependency.
- Use platform-appropriate executable names and portable paths. Isolate native
  OS APIs in platform-specific files; do not add Windows-only requirements to
  shared engine or gameplay code.
- Run `pwsh -NoProfile -File tools/validate.ps1 -AllExamples` for headless checks.
  Add `-Runtime` for the optional graphics/audio validators. Linux runtime checks
  require a desktop session or Xvfb; see `docs/linux.md`.
- Require passing Windows and Linux checks before releases. Distinguish source
  inspection, compilation, virtual-display tests, and real desktop verification.
  Never mark Linux tested based only on Windows runs or source inspection.

### Build Output

Place generated executables in the repository `build/` directory. When using
the Odin compiler, provide an explicit output path, for example:

```powershell
odin build examples/hello_world -collection:rune=rune -out:build/hello_world.exe
```

When possible, add small validation examples or test programs for:
- Loading `project.json`
- Loading scene JSON
- Creating entities
- Registering components
- Deserializing built-in components
- Rendering a simple sprite
- Reloading a modified scene
- Loading input mappings

If formal tests are not practical yet, create runnable examples under `examples/`.

---

## Runtime Console Commands for Coding Agents

Use the local console inbox to invoke registered commands in a running game
without keyboard focus. Run these examples from the repository root.

Build the example, then launch it with an opt-in inbox:

```powershell
odin build examples/tilemap_2d -collection:rune=rune -out:build/tilemap_2d.exe
Start-Process -FilePath ./build/tilemap_2d.exe -ArgumentList '--console-dir=build/console/tilemap' -WorkingDirectory (Get-Location).Path -WindowStyle Hidden
```

After the game creates its inbox directory, send commands with the helper:

```powershell
# List all registered commands, including game-specific commands.
./tools/console.ps1 -Directory build/console/tilemap -Command 'help'

# Save a frame to an automatically named PNG under build/captures/.
./tools/console.ps1 -Directory build/console/tilemap -Command 'capture'

# Save a frame to a specific PNG path.
./tools/console.ps1 -Directory build/console/tilemap -Command 'capture build/captures/tilemap.png'

# Clear the developer console output.
./tools/console.ps1 -Directory build/console/tilemap -Command 'clear'
```

### AI inspection and control

Add `-Json` to return one structured response with `ok`, `lines`, and `data`.
Use the data object directly instead of parsing human-readable log strings:

```powershell
$reply = ./tools/console.ps1 -Directory build/console/tilemap -Command 'status' -Json | ConvertFrom-Json
$reply.data
```

Available engine commands:

| Command | Behavior |
| --- | --- |
| `status` | Scene, frame number, simulation time, fixed-step count, FPS, pause state, active 2D/3D cameras, entity count, and recent errors. |
| `entities [component]` | Sorted entity IDs, names, parents, and component names; optionally filter by registered component. |
| `inspect <entity-id> [component]` | Current runtime component values and hierarchy. Runtime-only entities use the `@handle` returned by `entities`; handles expire on reload. |
| `pause` / `resume` | Stop/start simulation updates while rendering, console polling, hot reload, and audio servicing continue. |
| `step [count]` | While paused, advance 1–600 simulation updates using the fixed timestep, one per rendered frame. Default: 1. Reply arrives after completion; the game remains paused. |
| `input <action> press\|release\|clear` | Override a mapped input action. Edges are consumed by simulation, so a press while paused reaches the next step. `release` holds the action up; `clear` restores physical input. |
| `set <entity-id> <Component.field> <JSON-value>` | Validate and replace an existing runtime field without saving files. Dotted numeric segments address arrays, e.g. `Transform.position.0`. Entire vectors can be supplied as JSON arrays. |
| `reload` | Reload the active scene from disk, discard runtime scene edits, and invoke scene-reload callbacks. Invalid scene data leaves the current World intact. |
| `logs [since-sequence]` | Return log entries with sequence/level/message, a `next_sequence` cursor, and a `truncated` flag when older entries were dropped. |
| `profile [frames]` | Measure 1–600 rendered frames (default: 120). Return mean/max/p95 milliseconds for frame duration, update, fixed update, and render submission. Frame duration includes presentation/wait; these are CPU timings, not GPU measurements. |
| `capture [path.png]` | Return the saved absolute path, dimensions, frame number, simulation time, fixed-step count, scene, and active cameras. Frame details are under `data.metadata`. |

Example repeatable inspection workflow:

```powershell
./tools/console.ps1 -Directory build/console/tilemap -Command 'pause' -Json
./tools/console.ps1 -Directory build/console/tilemap -Command 'entities SpriteRenderer' -Json
./tools/console.ps1 -Directory build/console/tilemap -Command 'inspect knight Transform' -Json
./tools/console.ps1 -Directory build/console/tilemap -Command 'input move_right press' -Json
./tools/console.ps1 -Directory build/console/tilemap -Command 'step 5' -Json
./tools/console.ps1 -Directory build/console/tilemap -Command 'input move_right release' -Json
./tools/console.ps1 -Directory build/console/tilemap -Command 'step 1' -Json
./tools/console.ps1 -Directory build/console/tilemap -Command 'capture build/captures/after-step.png' -Json
./tools/console.ps1 -Directory build/console/tilemap -Command 'input move_right clear' -Json
./tools/console.ps1 -Directory build/console/tilemap -Command 'resume' -Json
```

`step` and `profile` finish before another command is dispatched. Increase
`-TimeoutSeconds` for long runs, especially at low FPS. Scene inspection, edits,
and reload require the scene loop; callback loops support timing, pause/step,
input, logs, profiling, and captures. Keep gameplay changes in update/fixed-update
callbacks so pausing simulation does not mutate game state through draw callbacks.
Runtime edits use the same notifications and cache updates as typed setters.
Shape or scale edits rebuild the affected native physics body; animator asset,
clip, or autoplay changes reset playback. To persist an
edit, change the source JSON explicitly; no command automatically saves a scene.

- Use a separate inbox directory for each running game. The inbox is disabled
  unless the game is launched with `--console-dir=<directory>`.
- `capture [path.png]` saves the completed game frame before the developer
  console overlay. Game UI and enabled gizmos are included. Relative paths
  resolve from the game's working directory; parent directories are created.
- The helper waits for a reply, prints console output, and reports command
  failures. Its default timeout is 10 seconds; override with `-TimeoutSeconds`.
  A timeout removes unclaimed requests, but a claimed command may still finish;
  check the result before retrying commands with side effects.
- Commands run on the game thread, with inbox polling at most ten times per
  second. Send one command of at most 256 UTF-8 bytes per helper invocation.
- Prefer this helper over simulated keyboard input or adding one-off capture
  code to examples. Open the saved PNG to verify rendering when relevant.
- The same commands work in the in-game console (backtick to open) or through
  `console.execute(rune.developer_console(&game), "capture")` from Odin.

---

## Long-Term Features

Possible later features:

### Editor
- Scene view
- Game view
- Inspector
- Asset browser
- Console/log window
- Entity hierarchy
- Transform gizmos
- Drag/drop asset assignment
- Component add/remove UI

### Runtime
- 3D model rendering
- Materials
- Shaders
- Skeletal animation
- Tilemaps
- Particles
- Physics integration
- Audio mixer
- UI system
- Save/load system

### Tooling
- Asset compiler
- Project validator
- Scene diff tool
- Prefab override viewer
- Export/build command
- JSON schema generation
- Asset dependency graph

### Developer Experience
- Live JSON reload
- Better errors with file/line paths
- Runtime console
- Debug draw tools
- Profiler overlay
- Entity/component inspector in running game

---

## Product Positioning

Possible positioning:

> A lightweight, data-driven Odin/raylib game engine for developers who want Unity-style scenes and prefabs without giving up code-first control.

The niche:
- Odin developers
- raylib developers
- solo developers
- people who want readable project files
- people who dislike heavy editor-first engines
- people who want a code-first workflow with optional visual tools

---

## Immediate Tasks for Coding Agents

Good first tasks:

1. Create the initial Odin project structure.
2. Add a minimal raylib window loop.
3. Create an `engine` package.
4. Implement `project.json` parsing.
5. Implement a `World` type with entity creation.
6. Implement `Transform`.
7. Implement `SpriteRenderer`.
8. Implement a simple component registry.
9. Load a scene JSON file.
10. Render sprites from loaded scene data.
11. Add input action mapping.
12. Add a simple example game.

First milestone:

> Load a scene from JSON and render a sprite entity on screen through raylib.
