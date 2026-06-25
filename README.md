# Rune

Rune is a small, code-first game engine written in Odin. Projects, scenes, and later prefabs are readable JSON files; gameplay behavior remains Odin code.

## Current slice

The initial scaffold provides:

- a raylib-backed engine loop;
- JSON `project.json` loading and scene-to-world instantiation;
- an ECS world with registered, JSON-backed custom components;
- cached texture assets and scene-owned 2D sprite rendering;
- a runnable hello-world example.

## Runtime lifecycle

The engine separates simulation from presentation using Unity-like callback
names. Pass an `on_update` procedure for gameplay and component-data changes,
and an `on_draw` procedure for camera/UI drawing and scene rendering:

```odin
rune.run(&game, on_update, on_draw)
```

`Transform`, `SpriteRenderer`, `MeshRenderer`, `SphereRenderer`, `Camera2D`, `Camera3D`, `AudioListener`, and `AudioPlayer` are data
components. Their behavior stays in Odin systems, rather than turning scene
JSON into scripts.

The engine caps simulation delta time at 0.1 seconds. Native window dragging
can pause a raylib frame loop; capping the resumed frame prevents movement and
physics from jumping across the world. Rendering still pauses while the OS owns
the window-drag operation.

## Optional registered systems

Games can register ordered Odin systems and run an instantiated world through
the ECS lifecycle. Update systems run before drawing; draw systems run after
the engine clears the project background. A system may also reacquire cached
entities after a scene hot reload.

```odin
rune.register_system(&game, rune.System{
  name = "draw_scene",
  draw = proc(game: ^rune.Engine, world: ^ecs.World) {
    render.draw_scene_2d(world, rune.asset_manager(game))
  },
})
rune.run_scene(&game, &world)
```

`rune.run` remains the simpler choice for small callback-based programs. The
dedicated registered-system example is available at:

```powershell
odin run examples/registered_systems -collection:rune=rune
```

## Runtime console

Every Rune engine instance includes a lightweight developer console. Press the
grave/backtick key (`` ` ``) to open it, `Esc` to close it, and use the up/down
arrows to navigate command history. The built-in `help` and `clear` commands
are always available. The console is rendered after game draw callbacks and
registered draw systems, so it remains visible over both 2D and 3D scenes.

Register game-specific commands from Odin. Command handlers own the game
behavior; the JSON formats remain declarative.

```odin
import "rune:console"

spawn_command :: proc(dev_console: ^console.Console, arguments: string) {
    console.info(dev_console, "Spawn requested")
    // Create game entities here.
}

dev_console := rune.developer_console(&game)
console.register(dev_console, "spawn", "Spawn a test entity.", spawn_command)
console.info(dev_console, "Game initialized")
```

The overlay handles text entry, but it does not automatically suppress project
input actions. A gameplay system that needs exclusive controls should check
`console.is_open(rune.developer_console(game))` and skip its input handling
while the console is open.

## Tweening and easing

`rune:tween` is a small code-only utility for transient interpolation such as
camera motion, UI fades, and gameplay feedback. It is not a scene component:
JSON continues to describe initial state, while Odin systems decide when a
tween begins. Create and update tween instances from a game's update callback
or registered update system.

```odin
import "rune:tween"

move := tween.make(0.35, tween.ease_out_cubic)

// In an update callback:
tween.update(&move, game.delta_time)
position := tween.value_vec2(&move, {0, 0}, {300, 120})
```

The package supplies linear, sine, quad, cubic, quart, back, bounce, and
elastic easing functions, along with scalar, 2D-vector, 3D-vector, and float
RGBA color interpolation. Set `mode` to `.Restart` or `.Ping_Pong` and
`repeat` to the number of additional passes (`-1` repeats indefinitely) when
needed. Run its non-windowed validation with:

```powershell
odin run tools/tween_validation -collection:rune=rune
```

The runnable [`tweening_2d`](examples/tweening_2d) example loads an orb from
scene JSON, then uses a ping-pong tween to animate its position and color.
Left-click to cycle through easing equations:

```powershell
odin run examples/tweening_2d -collection:rune=rune
```

[`scene_transition_2d`](examples/scene_transition_2d) demonstrates replacing
the runtime `World` with another JSON scene. A left click fades to black,
loads the next scene, then fades back in:

```powershell
odin run examples/scene_transition_2d -collection:rune=rune
```

[`third_person_3d`](examples/third_person_3d) demonstrates a code-driven
third-person controller: the player and active camera are separate JSON
entities, while Odin moves the player relative to camera yaw and updates the
follow camera. The JSON scene supplies `CharacterController`, static
`BoxCollider`, and `SphereCollider` components. Use WASD to move, Space to
jump, use the mouse wheel to zoom, hold the left mouse button to orbit only
the camera, or hold the right mouse button to orbit and turn the player.

```powershell
odin run examples/third_person_3d -collection:rune=rune
```

## Project display settings

`project.json` can set the window clear color as an RGBA byte array. Projects
without this field retain the default white background.

```json
"background_color": [48, 48, 48, 255]
```

Enable raylib's 4× MSAA hint for smoother geometry edges before the window is
created:

```json
"window": {
  "msaa_4x": true
}
```

The default is `false`. MSAA availability is platform and graphics-driver
dependent; raylib falls back when the requested framebuffer cannot be created.

## Input actions

Each project may point `input` at an input mapping JSON file. The engine loads
and validates it during `rune.init`, then samples its bindings before every
`on_update` callback. Actions support one or more keyboard or gamepad-button
bindings; axes combine two named actions into a signed value.

```json
{
  "actions": {
    "move_left":  [{ "type": "keyboard", "key": "A" }],
    "move_right": [{ "type": "keyboard", "key": "D" }],
    "jump": [{ "type": "gamepad_button", "button": "A", "gamepad": 0 }]
  },
  "axes": {
    "move_x": { "negative": "move_left", "positive": "move_right" }
  }
}
```

Query the state from an update system. `is_down`, `pressed`, `released`, and
`strength` apply to actions; `axis` returns a value from `-1` to `1`.

```odin
import "rune:input"

move_x := input.axis(rune.input_state(game), "move_x")
if input.pressed(rune.input_state(game), "jump") {
    // Start a jump.
}
```

Keyboard names currently include letters, digits, arrows, `SPACE`, `ESCAPE`,
`ENTER`, `TAB`, `BACKSPACE`, shift, and control. Mouse buttons use `LEFT`,
`RIGHT`, or `MIDDLE`. Gamepad buttons use readable names such as `A`, `B`,
`X`, `Y`, `DPAD_UP`, `LEFT_BUMPER`, and `START`.

## Runtime key rebinding

Game code can replace an action's keyboard binding at runtime. This preserves
any mouse or gamepad bindings declared for that action, and axes automatically
use the new action state on the next input update.

```odin
controls := rune.input_state(game)
if input.rebind_keyboard(controls, "move_left", "LEFT") &&
   input.rebind_keyboard(controls, "move_right", "RIGHT") {
    input.save(controls) // Writes the JSON input file loaded by the project.
}
```

The runnable [`runtime_rebinding`](examples/runtime_rebinding) sample starts
with `A`/`D` movement. Press `R` to switch it to Left/Right arrows and press
`R` again to restore `A`/`D`; each change is saved to
`input/default.input.json`:

```powershell
odin run examples/runtime_rebinding -collection:rune=rune
```

Mouse motion can be exposed as an axis using `"type": "mouse_delta"` and
`"axis": "x"` or `"y"`. Its value is the mouse movement sampled for the
current frame; optional `scale` and `invert` fields may be provided. For
example, `{ "type": "mouse_delta", "axis": "y", "invert": true }`
reverses vertical mouse movement.

Mouse-wheel input is available as `{ "type": "mouse_wheel" }`; it returns
the wheel movement sampled for the current frame and also supports `scale` and
`invert`. The third-person example uses it to zoom its follow camera.

`third_party/r3d` is pinned to r3d `v0.10.0` and is reserved for the engine's later 3D renderer. The first example deliberately uses the bundled Odin raylib binding so the 2D foundation stays small.

## Run the example

From the repository root on Windows:

```powershell
odin run examples/hello_world -collection:rune=rune
```

The example loads `project.json`; `scene.load` then reads `scenes/main.scene.json` and returns its populated runtime `World`.

## Project validation

Use the non-windowed validator before running a project or in CI. It follows
the startup scene and its prefabs, checks entity IDs and layers, confirms
referenced input and asset files exist, and reports failures as
`file: $.json.path: message`.

```powershell
odin run tools/project_validator -collection:rune=rune -- examples/hello_world/project.json
```

The project path is optional and defaults to the hello-world example. Runtime
project and scene loading use the same structural validation before creating a
window or world.

## Custom components

`rune.init` automatically creates the component registry and registers the
built-ins. Scene instantiation discovers component names recursively and
automatically registers missing names as JSON-backed custom components. This
means a scene can declare `Health` or `Mover` without an earlier registration
call. Game code still owns behaviour: automatic registration does not generate
an Odin type or system from JSON.

```odin
entity := ecs.create_entity(&world)
ecs.register_component(rune.component_registry(&game), ecs.Component_Descriptor{
    name = "Health",
    description = "Hit points for damageable entities",
})
ecs.add_component(&world, rune.component_registry(&game), entity, "Health", health_json)
```

`health_json` is a `json.Value`; it can come directly from a scene or prefab JSON
component block. Typed Odin component storage and serializers can be added later
without changing the JSON-facing format.

The typed built-ins are `Transform`, `SpriteRenderer`, `MeshRenderer`,
`SphereRenderer`, `Camera2D`, `Camera3D`, `AudioListener`, and `AudioPlayer`. Cameras use their entity's
`Transform` for their position; only one camera of a given kind should be
active at a time. Custom-component systems can read and modify `Transform` by
entity ID:

```odin
transform, ok := ecs.get_transform(&world, entity)
if ok {
    transform.position[0] += speed * dt
    ecs.set_transform(&world, entity, transform)
}
```

## Audio component data

`AudioListener` selects the scene audio reference point and normally belongs on
the active camera entity. `AudioPlayer` belongs on entities that emit sounds.
The sound path is project-relative; Odin audio systems own playback commands.
The runtime initializes raylib audio, loads one independent sound instance per
player entity, honors `play_on_start`, and restarts looping sounds. Spatial
players use listener-relative distance attenuation and world-X panning as an
initial simple mixer; orientation-aware 3D audio can replace this later.

```json
"AudioListener": { "active": true }
```

```json
"AudioPlayer": {
  "sound": "assets/audio/bell.wav",
  "volume": 0.75,
  "pitch": 1.0,
  "looping": false,
  "spatial": true,
  "min_distance": 1.0,
  "max_distance": 20.0,
  "play_on_start": false
}
```

Use `ecs.active_audio_listener` and `ecs.set_active_audio_listener` to manage
the selected listener. Scenes should declare one active listener; the ECS does
not require that listener to carry a camera component.

The runnable component-loading example is available at:

```powershell
odin run examples/audio_components -collection:rune=rune
```

When using `rune.run_scene`, the engine updates audio automatically. Odin
systems can trigger a configured player explicitly with
`rune.play_audio(game, world, entity)` and stop it with
`rune.stop_audio(game, entity)`.

## Entity tags and layers

Entity identity and filtering data are base World metadata, rather than ECS
components. Scene entities may declare an optional `tag` and zero or more named
`layers`. A missing `layers` field puts the entity in the implicit `Default`
layer (bit 0).

```json
{
  "id": "player",
  "name": "Player",
  "tag": "player",
  "layers": ["Gameplay", "Player"],
  "components": {}
}
```

`Default` is built in at bit 0. Projects define only additional names in
`project.json`; their positions must be between 1 and 63:

```json
"layers": {
  "Gameplay": 1,
  "Player": 2
}
```

Normal game code loads through the engine, which supplies the project's layer
table so named layers are validated and resolved into a `u64` mask:

```odin
world, ok := rune.load_scene(&game, scene_path)
```

`scene.load` remains available for standalone tools and resolves the built-in
`Default` layer without project configuration. Tools that load project-named
layers can use `scene.load_with_layers`.

Systems can resolve a scene ID once with `ecs.find_entity_by_id` and cache the
returned runtime handle for that World. IDs are unique when non-empty; names
are display metadata and may be duplicated. Systems can inspect metadata with `ecs.entity_id`, `ecs.entity_name`,
`ecs.entity_tag`, `ecs.has_tag`, `ecs.entity_layer_mask`, and
`ecs.is_in_layer_mask`. Tags are one optional string; layers are a bitmask and
are suitable for later render, camera, collision, and editor filtering.

## Scene-owned rendering

The scene renderer walks the entity hierarchy. For every entity, it pushes a
matrix, applies its `Transform`, draws its supported render component, draws
its children in that transformed space, then pops the matrix. A normal game
system therefore only changes component data; it does not call `rlgl.PushMatrix`,
`rlgl.PopMatrix`, or draw a `MeshRenderer`/`SphereRenderer` itself.

```odin
render.draw_scene_3d(&world, scene_view)
```

`MeshRenderer` currently draws the `cube` primitive and `SphereRenderer` draws
a sphere. `SpriteRenderer` loads a project-relative texture path through the
asset cache and draws it through the active `Camera2D`:

```odin
render.draw_scene_2d(&world, rune.asset_manager(game))
```

Missing sprite textures use a shared magenta fallback texture rather than
retrying disk loading every frame.

Validate scene-to-typed-transform loading without starting a game window:

```powershell
odin run tools/component_validation -collection:rune=rune
```

## 3D hello world

The 3D sample loads a JSON scene and shows a rotating cube with a perspective camera:

```powershell
odin run examples/hello_3d -collection:rune=rune
```

## JSON sprite scene

This separate 2D example defines a game-owned `TiledWall` component in scene
JSON for the `wallDark.png` background, then renders a randomly moving
`skeletonWarrior.png` `SpriteRenderer` through the active `Camera2D` and the
engine texture cache:

```powershell
odin run examples/sprite_scene_2d -collection:rune=rune
```

## Prefabs

Scenes can instantiate a prefab using a path relative to the scene file. The
instance keeps scene-owned metadata such as `id`, `name`, `tag`, and `layers`;
its `components` replace matching prefab component blocks. This initial slice
supports prefab child entities, but not nested prefab references or child-level
overrides.

```json
{
  "id": "skeleton_left",
  "prefab": "../prefabs/skeleton.prefab.json",
  "components": {
    "Transform": { "position": [180, 270, 0], "scale": [3, 3, 1] }
  }
}
```

Run the multiple-instance example with:

```powershell
odin run examples/prefabs_2d -collection:rune=rune
```

Validate prefab scene loading without opening a window:

```powershell
odin run tools/prefab_validation -collection:rune=rune
```

## Development hot reload

Configure modified-time polling in `project.json`. These values default to the
following when the block is omitted:

```json
"hot_reload": {
  "enabled": true,
  "poll_interval_ms": 250,
  "scenes": true,
  "prefabs": true,
  "textures": true,
  "models": true
}
```

Texture reload respects `textures`. Scenes are opt-in at the game-code level
because a reload replaces the `World` and invalidates cached entity handles.
Call this in a game's update callback:

```odin
if rune.reload_scene_if_changed(game, &world, "scenes/main.scene.json") {
    // Reacquire any Entity values cached by this game.
}
```

The helper respects `enabled`, `scenes`, and `prefabs`, and watches the scene
JSON plus directly referenced prefab files when configured to do so.

## Asset-backed 3D models

`ModelRenderer` loads a model through the project asset cache and renders it
with the entity `Transform` through the active `Camera3D`:

```json
"ModelRenderer": {
  "model": "assets/models/pyramid.obj",
  "tint": [210, 220, 255, 255]
}
```

`hot_reload.models` controls modified-time model refresh. The built-in
`MeshRenderer` and `SphereRenderer` remain useful debug primitives. Run the
self-contained OBJ example with:

```powershell
odin run examples/model_scene_3d -collection:rune=rune
```

## Basic 3D collision

`BoxCollider` provides static axis-aligned world collision. `SphereCollider`
provides a conservative sphere-shaped static volume whose radius follows the
largest Transform scale axis. `CharacterController` adds gravity, grounded
state, and jumping while keeping its entity Transform at the camera eye
position. Colliders only interact when their entity layer masks overlap.

```json
"BoxCollider": { "size": [1, 1, 1], "is_static": true }
```

```json
"SphereCollider": { "radius": 0.75, "is_static": true }
```

```json
"CharacterController": {
  "radius": 0.35,
  "height": 1.8,
  "eye_height": 1.6,
  "gravity": 24,
  "jump_speed": 8
}
```

The first-person example now has collidable blockout geometry. Use WASD to
move, Space to jump, and Escape to release/capture the cursor. Green outlines
show static collision boxes.

## 2D tilemaps

`TilemapRenderer` draws a JSON grid from a texture atlas. Each non-negative
cell selects an atlas tile; `-1` leaves that cell empty.

```json
"TilemapRenderer": {
  "texture": "assets/tiles/dungeon.png",
  "tile_size": [16, 16],
  "grid": [[0, 0, -1], [0, 1, 0]]
}
```

Run the example with:

```powershell
odin run examples/tilemap_2d -collection:rune=rune
```

`TilemapCollider` uses the same grid and blocks indices in `solid_tiles`.
`TopDownController` gives an entity a 2D collision size and movement speed;
game code supplies input deltas to `ecs.move_top_down`, which resolves X and Y
separately for wall sliding. Run the collision example with:

```powershell
odin run examples/tilemap_collision_2d -collection:rune=rune
```

## Fixed-step 2D physics

`RigidBody2D` is an engine-owned JSON component backed by Odin's `vendor:box2d`
package.
The runtime synchronizes its velocity and Transform at a fixed 60 Hz, while
Box2D handles dynamic contacts, friction, and continuous collision. An entity
with a collider but no `RigidBody2D` becomes static collision geometry.

```json
"RigidBody2D": { "gravity_scale": 1.0 },
"BoxCollider2D": { "size": [26, 30] }
```

Call `ecs.physics_2d_update(&world, game.delta_time)` after game code updates
the body's velocity. `grounded` is set after a body lands, which makes jumping
an explicit game-code decision. Run the example and non-windowed validation:

```powershell
odin run examples/physics_platformer_2d -collection:rune=rune
odin run tools/physics_2d_validation -collection:rune=rune
```

## Scene text

`TextRenderer` draws font-backed text through an entity `Transform` and the
active `Camera2D`. Fonts are cached with textures and refresh when their file
changes.

```json
"TextRenderer": {
  "text": "WASD: move",
  "font": "assets/fonts/mecha.png",
  "font_size": 18,
  "color": [255, 255, 255, 255]
}
```

## Multiple camera switching

The camera-switching sample has three `Camera3D` entities loaded from JSON.
Press `1`, `2`, or `3` to select the wide, front, or side camera:

```powershell
odin run examples/camera_switching -collection:rune=rune
```

## Orbit camera

This example updates the `Transform` of an active `Camera3D` entity, orbiting
the camera around the `target` stored in its scene component. It orbits
automatically; hold the left mouse button and drag to control the orbit:

```powershell
odin run examples/orbit_camera -collection:rune=rune
```

## First-person controller

This noclip 3D sample demonstrates a game-owned `FirstPersonController`
component declared in scene JSON. Its Odin system reads project input actions,
updates the camera entity's `Transform`, and updates its `Camera3D.target`.

```powershell
odin run examples/first_person_3d -collection:rune=rune
```

Use WASD to move, Shift to sprint, and mouse movement to look. Escape releases
or recaptures the cursor. Collision, gravity, and jumping are intentionally
deferred until a physics/collision slice exists.

## Solar-system hierarchy

This sample shows nested scene entities and transform inheritance: `Sun > Earth > Moon`.

```powershell
odin run examples/solar_system -collection:rune=rune
```

## Custom component updating a Transform

This example lets scene loading auto-register the game-defined `Mover`
component. Its JSON `speed` value is read by an Odin system, which updates the
entity's typed `Transform` every frame.

```powershell
odin run examples/custom_mover -collection:rune=rune
```
