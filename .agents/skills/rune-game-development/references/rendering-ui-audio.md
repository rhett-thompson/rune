# Rendering, UI, and audio

Resolve every repository path below relative to `RUNE_ROOT`. Ordinary component
asset paths default to `GAME_ROOT`; see [gameplay-and-scenes.md](gameplay-and-scenes.md)
for the explicit `prefab://` path prefix.

## Rendering ownership

The scene-owning `rune.run(&game)` loop calls `render.draw_scene_2d` automatically.
Provide an active `Camera2D` entity with its own `Transform`; the renderer derives
the target from that transform and draws configured sprites, tilemaps, text,
particles, and shapes. Do not draw the same scene again in a registered `draw`
callback. Inspect `rune/core/core.odin` and `rune/render/render.odin`; start with
the sprite scene example (`examples/sprite_scene_2d/README.md`).

3D rendering requires an explicitly owned `r3d_bridge.Context`. Initialize it
after `rune.init` creates the window, check success, call
`r3d_bridge.draw_scene` or `draw_scene_ex` from the owning system's `draw`, and
call `r3d_bridge.shutdown` from its shutdown callback before the engine closes
the window. The bridge owns its native renderer and caches; `Engine` does not
destroy a separately created bridge. Follow
Hello 3D (`examples/hello_3d/main.odin`) and
`rune/r3d_bridge/r3d_bridge.odin`, including guarded initialization when handling
scene reloads. If a system releases resources in `shutdown`, initialize them in
both `start` and `on_save_restored` when saves are enabled: restoration does not
call `start`. Structural hot reload uses `on_scene_reloaded` without shutdown;
retain valid resources and refresh their World-dependent references there.
Builds importing the bridge also need
`-collection:r3d=<RUNE_ROOT>/third_party/r3d-odin`; JSON components alone do not
initialize or draw R3D. For animated models, explicitly advance
`r3d_bridge.update_animations` during update; drawing alone does not advance time.
For relocatable games, pass `game.project_directory` as the bridge's root after
`rune.init_project()` (or explicit `rune.init`). The bridge has its own root;
hard-coded example paths do not become portable just because core startup is.

## Orbit navigation in tool viewports

`ecs.OrbitCamera3D` stores a world-space target/distance and yaw/pitch in degrees.
Use `ecs.default_orbit_camera_3d()` before applying overrides. Existing defaults
retain camera-plane panning (`pan_mode = .screen`) and world-unit wheel zoom
(`zoom_mode = .absolute`). Choose `.horizontal` panning to move on world XZ
without changing target Y. Relative zoom changes distance by
`-zoom * distance * zoom_sensitivity`; it affects the wheel/zoom axis, while
held pad zoom remains world units/second. See `docs/components.md`, OrbitCamera3D,
and `rune/ecs/camera.odin` for the complete contract.

The mapped `ecs.update_orbit_camera_3d(&orbit, &game.input, dt)` overload respects
gameplay input capture. For a game-owned viewport, pass an
`ecs.Orbit_Camera_Input` value instead: `orbiting`/`panning` enable gestures,
`orbit_delta`/`pan_delta` are per-frame displacements, and positive `zoom` moves
toward the target. `pad_orbit` contains normalized rate axes and positive
`pad_zoom` moves away; `dt` scales those rate inputs. Panning takes priority over
orbiting. The caller owns viewport focus, modal gating, and drag capture; the
resolved overload does not change global input capture.

For navigation while paused, call the resolved overload once from `ui_update`
with frame delta time. The scene's automatic orbit update remains tied to
simulation; avoid advancing the same camera twice. Tool state need not be an ECS
entity. Both overloads return a world-space `Transform`; use `orbit.target` for
`Camera3D.target` and convert position into parent-local space when storing it
on a parented entity. `ecs.orbit_camera_3d_pose(orbit)` evaluates the current
world pose without advancing time or input, suitable for drawing and picking.
The game continues to own selection/floor framing, cutaway rules, and preview
scale.

`rune/ecs/orbit_camera_input_test.odin` covers resolved/mapped input, pan/zoom
modes, pause-independent mouse displacement, snapshot round trips, and typed
mode validation. These tests and `tools/component_validation` pass on Windows;
physical viewport focus and mouse drag capture still need game-level exercise.

## Transform and collision conventions

For 2D layering, set each rendering component's `draw_order`; Transform Z does
not determine drawing order. Native 2D colliders use the entity's own position
and scale, keep body rotation fixed, and ignore parent transforms and Transform
rotation. Moving a visual parent or rotating a sprite can therefore separate
rendering from collision. Choose collider geometry/orientation according to
`docs/physics.md`; verify authoring against `rune/ecs/physics_2d.odin` and
`rune/render/render.odin` rather than assuming matching transform behavior.

## Choose collision queries or rendered picking

Use `ecs.physics_2d_raycast`/`physics_3d_raycast` for native colliders and
`r3d_bridge.scene_raycast` for supported rendered geometry, including render-only
meshes. Both take an origin and bounded translation: use `end - origin` or a
normalized direction multiplied by the intended range.

Rendered picking supports cubes, planes, quads, spheres, and runtime static
meshes. Imported models require a supplied bridge with those assets already
cached; queries do not load them. Model hits use conservative static bounding
boxes, so recesses and animated poses are not tested. These queries follow the
composed 3D hierarchy, exclude terrain and volumes, and do not evaluate shader
displacement or transparency. Read `rune/r3d_bridge/scene_query.md` and
`docs/physics.md` before selecting a query. For character-capsule hits, follow
the separate controller query guidance in
[gameplay-and-scenes.md](gameplay-and-scenes.md).

For a read-only scene query without an R3D dependency, use
`render.scene_pick_2d(world, assets, world_point)` or
`render.scene_pick_3d(world, origin, translation, assets)`. The 2D query follows
render hierarchy and draw order for shapes, sprite/text bounds, occupied tiles,
and live particles. It borrows cached textures/fonts when dimensions are needed.
The 3D query returns the nearest supported primitive, sphere, runtime static
mesh triangle, or cached imported model bound. Its translation is a bounded
segment, as with raycasts above. Imported model bounds are CPU metadata
published to the asset manager after successful renderer loads; the renderer
continues to own the model resources. Neither query loads assets or uses native
colliders. See `rune/render/picking_2d.odin`, `rune/render/picking_3d.odin`, and
`rune/assets/assets.odin`.

To form a bounded 3D picking segment without a graphics context, current core
exposes `rune.debug_pick_camera_ray(camera, point, viewport, near, far)`. Its
screen point and dimensions are in the presented canvas coordinate system;
convert native mouse coordinates first when the game uses a scaled canvas.
It returns origin, translation and validity for perspective or orthographic
cameras. Raylib also exposes `GetScreenToWorldRay`/`GetScreenToWorldRayEx`;
`GetMouseRay` is not the name in the pinned binding. For interactive move/rotate
handles, use `rune/gizmos/transform_3d.md`; the caller owns input, document edits
and undo history. See `rune/core/debug_picking.odin` and `rune/render/resolution.odin`.

The open runtime console uses these queries when clicking outside its panel:
an active `Camera3D` hit takes priority, then an active `Camera2D` hit. This
inspects the current entity without retaining scene pointers or changing the
command draft. It retains only the selected entity handle and picking dimension,
recomputes its own supported rendered bounds each frame, and draws amber corner
brackets with a dark backing. The native debug overlay runs after the game canvas,
game UI, and console frame capture, before the console panel. It needs no F3
gizmos or GPU resources and changes no materials, shaders, depth state, or entity
data. Closing the console, clicking empty canvas, rebinding the scene, or deleting
the selected entity clears it. Disabling the entity or an ancestor, offscreen
bounds, or otherwise temporarily undrawable bounds hide the brackets while
retaining a valid selection.
Engine entity commands can resolve this selection as `@picked`; custom commands
can query `rune.debug_picked_entity(game)` for the current handle and validity.
The alias, component completion, and field completion remain valid while the
entity is disabled, so `enable @picked` can restore its local activation flag.
A disabled ancestor still keeps it inactive. The alias clears with the selection
and never retains scene pointers. Console
focus temporarily shows a free cursor, allowing picks in first-person games;
set the desired gameplay cursor mode with `rune.set_cursor_mode` so closing the
console restores it. See `docs/runtime-console.md` (Cursor ownership).

For the same CPU-only bounds, use
`render.scene_selection_bounds_2d(world, assets, entity, camera)` or
`render.scene_selection_bounds_3d(world, assets, entity, camera, viewport, near, far)`.
They return a rectangle in canvas coordinates plus a valid flag. The console
maps those coordinates through canvas presentation into native logical UI space.
These helpers borrow scene/cache data and do not load assets. Geometry queries
do not test texture transparency, animated model deformation, shader displacement,
terrain, or volumes. Custom draw calls/cameras
and mixed rendering order can differ from this picking policy. See
`docs/runtime-console.md` (Picking scene objects) and
`rune/core/debug_picking.odin`.

Geometry and coordinate tests live in `rune/render/picking_2d_test.odin`,
`rune/render/picking_3d_test.odin`, `rune/render/selection_2d_test.odin`,
`rune/render/selection_3d_test.odin`, `rune/core/debug_picking_test.odin`, and
`rune/core/debug_selection_test.odin`.
`tools/debug_console_validation` also accepts `--runtime` to check picks against
rendered pixels and selection overlays. Console captures require a non-hidden
window; the validator reveals for successful capture cases and separately checks
hidden capture errors. Earlier pixel checks were verified on
Windows with OpenGL 3.3/NVIDIA at 1000x800 logical and framebuffer resolution,
using a 400x400 fit canvas and perspective and orthographic 3D cameras. These
fixtures check live bounds, unchanged object surface colors and pixels outside
the brackets, visible amber markers, and clean console frame captures. This does
not establish coverage for custom drawing, animated model deformation, other
graphics backends, or physical HiDPI displays; headless coordinate tests cover
simulated framebuffer scaling separately.

For console-driven runs, project `window.hidden: true` retains the graphics
context while suppressing automatic reveal. Use `rune.set_window_hidden` for
runtime visibility, and reveal/settle before console capture. Readback happens
before presentation; requiring visibility is a supported capture contract, not
a claim that every hidden framebuffer read fails. See `docs/display.md` and
`rune/console/capture.odin`.

## Live material authoring

For live material authoring, `assets.set_material_preview(manager, path, data)`
owns a deep copy and invalidates existing R3D material/instance caches through
the asset revision. All uses of the same path share the preview. Getters return
borrowed strings; clone retained values with `assets.clone_material_data` and
release them with `destroy_material_data`. `material_data` sees the preview;
`authored_material_data` bypasses it. Clear one or all previews when live
authoring ends. Saving remains tool-owned: write JSON preserving required source
fields, call `refresh_materials`, then clear the preview. See
`docs/procedural-materials.md` and `rune/assets/material_preview.odin` for
ownership and authoring limits.

Imported models can share default slot paths through the optional
`<model path>.materials.json` sidecar (`{"materials":{"0":"materials/body.json"}}`).
The bridge applies these below explicit `ModelRenderer.material` and
`ModelRenderer.materials` overrides, including instanced rendering.
`assets.model_material_paths`/`model_material_path` borrow cached defaults;
`refresh_materials` watches optional sidecar creation, changes, and removal.
Invalid replacement JSON retains the previous mapping. Paths inside the sidecar
are project-relative. See `docs/components.md` (ModelRenderer) and
`rune/assets/model_materials.odin`.

## Canvas and coordinates

Read display settings (`docs/display.md`) before custom drawing or picking.
`pre_draw`, automatic 2D scene rendering, registered `draw`, and gizmos share the
game canvas. `draw_ui` follows canvas presentation at native logical resolution.
Use `rune.canvas_size(game)` for game layout; convert pointer positions with
`rune.mouse_canvas_position(game)`, reject its false inside flag for letterbox
bars, then apply `rl.GetScreenToWorld2D` for world picking. Raw window mouse
coordinates do not describe a scaled reference canvas.

Use `GetScreenWidth/Height` for native UI coordinates and `GetRenderWidth/Height`
for physical framebuffer allocations. Avoid multiplying logical drawing or mouse
coordinates by DPI again. For custom camera drawing, enter from screen space
with `render.begin_camera_2d(camera)` and pair it with `rl.EndMode2D`; the helper
preserves the current screen transform and render-texture coordinates
(`rune/render/camera.odin`). Prefer native output plus bridge render scaling for
3D rather than the 2D reference canvas.

## Clay UI and input

Declare Clay widgets and layout in Odin; Rune has no separate UI JSON format.
Keep initialized `ui.Context` storage at a stable address; do not return or copy
it. Initialize after the window exists and destroy before window shutdown. The
context owns its arena but borrows fonts/textures, which must remain valid.
The UI guide (`docs/ui.md`), Clay example (`examples/clay_ui/main.odin`), and
`rune/ui/ui.odin` define the lifecycle; Clay requires no additional collection.

Build once per frame in `ui_update`, including while paused. Read
`ui.read_input(&context, rune.input_state(game), game.frame_delta_time)` once,
preserve its blocked state, and also block when the console owns input. Call
`input.capture` every frame a modal owns gameplay input, including its closing
frame. Balance panels and `ui.begin`/`ui.finish`; render commands in `draw_ui`
outside camera modes. Use stable unique widget IDs. Custom loops call
`rune.begin_frame` before updates to sample input/console, then explicitly drive
layout and drawing; the low-level callback `run` overload does not dispatch
registered systems. See `rune/ui/input.odin` for mapped or synthetic inputs.

Use `ui.scroll_panel` for long control lists. Explicit next/previous navigation
reveals focused widgets inside their containing scroll panels, including nested
viewports; idle focus preserves mouse-wheel scroll positions. The context input
overload above adds controller left-stick navigation and repeat to mapped D-pad
and keyboard actions.

Text inputs clip their contents and each consumes a native Clay scroll entry.
Rune's patched header sizes these entries by the element limit, supporting
inspectors with many numeric fields. Native artifacts must be rebuilt from that
header; see `third_party/clay/README.rune.md` and the many-field regression in
`rune/ui/scroll_nested_test.odin` when diagnosing native capacity errors.
The patched Windows AMD64 object and Linux AMD64 archive passed all 30 serial
headless UI tests on 2026-10-18; Linux coverage used Ubuntu WSL. Other targets
and rendered-pixel behavior are not established by those headless tests.

## Audio lifetime and commands

The engine owns its audio system across scene changes. Avoid additional raw
`InitAudioDevice`/`CloseAudioDevice` calls; an existing device is borrowed, and
its owner must outlive borrowers. Address repeatable `AudioPlayer` components
by entity and instance name: `rune.play_audio(game, world, entity, "bell")`,
`stop_audio`, and `preload_audio`. Preloading loads buffered variants and reserves
voices without playing or randomly choosing a clip; streams retain one channel.
Configure an active `AudioListener` for spatial playback. Automatic servicing
continues while paused, which does not itself mute audio. Raw raylib playback
bypasses Rune's mixer. Read audio buses (`docs/audio-mixer.md`),
Audio Components (`examples/audio_components/main.odin`), and ownership sources
`rune/audio/audio.odin`, `rune/audio/preload.odin`, and `rune/core/core.odin`.

| Specialized work | Read next |
| --- | --- |
| Skeletal/sprite animation, markers, and transitions | `docs/model-animation.md`, `docs/model-animation-events.md`, `docs/animation-events.md`, `docs/animation-transitions.md` |
| Materials and foreground rendering | `docs/procedural-materials.md`, `docs/overlays-3d.md` |
| Post-processing and asset examples | `examples/post_processing_3d/README.md`, `examples/procedural_material_3d/README.md`, `docs/asset_credits.json` |
