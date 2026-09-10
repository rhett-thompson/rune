# Examples

Start with **Sprite Scene 2D** for the smallest scene-to-screen example, or follow
Basics in order for component registration, movement, and prefabs. Feature demos
focus on one engine facility; games show how those pieces fit together.

Run commands from the repository root. Keep each example in place: some use assets
from neighboring examples. The launcher supplies any extra collections:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/launcher -collection:rune=rune "-out:build/launcher$exe"
```

These commands use PowerShell 7 on Windows or Linux. Each guide below also has a
direct run command. For R3D setup and Linux display requirements, see
[Linux development](../docs/linux.md) and the [repository README](../README.md).

Scene examples hot reload JSON when saved. Odin changes require a rebuild. Close
the window to quit; the developer console is available with the backtick key.

## Basics

| Example | What it covers |
| --- | --- |
| [Hello World](hello_world/README.md) | A greeting loaded from a scene. |
| [Sprite Scene 2D](sprite_scene_2d/README.md) | One sprite, one camera, one scene. |
| [Custom Mover](custom_mover/README.md) | Your first movement component. |
| [Prefabs 2D](prefabs_2d/README.md) | Reuse a sprite with scene overrides. |

## 2D

| Example | What it covers |
| --- | --- |
| [Shapes 2D](shapes_2d/README.md) | Texture-free shapes, activation, and timed entity expiry. |
| [Sprite Animation 2D](sprite_animation_2d/README.md) | Sprite clips and playback controls. |
| [Tweening 2D](tweening_2d/README.md) | Compare six easing curves. |
| [Scene Transition 2D](scene_transition_2d/README.md) | Fade between two scenes. |
| [Checkpoint Saves](save_load_2d/README.md) | Save slots, pickups, spawned objects, and progress across rooms. |
| [Tilemap 2D](tilemap_2d/README.md) | Explore a layered, collidable map. |
| [Physics Platformer 2D](physics_platformer_2d/README.md) | Run and jump with 2D physics. |
| [Physics Queries 2D](physics_queries_2d/README.md) | Pickups, raycasts, and overlaps. |
| [2D Colliders](colliders_2d/README.md) | Capsules, offset shapes, sensors, and collider gizmos. |
| [2D Ramps](ramps_2d/README.md) | Slopes, moving platforms, one-way collision, jumps, and dashes. |
| [Particles 2D](particles_2d/README.md) | A fountain, smoke, and a burst. |
| [Clay UI](clay_ui/README.md) | A pause menu with focus and volume. |
| [Runtime Rebinding](runtime_rebinding/README.md) | Change and save movement keys. |

## 3D

| Example | What it covers |
| --- | --- |
| [Navigation 3D](navigation_3d/README.md) | Triangle navmeshes, click-to-move agents, ramps, and blocked routes. |
| [Hello 3D](hello_3d/README.md) | A rotating cube and a camera. |
| [Model Scene 3D](model_scene_3d/README.md) | Load a model and orbit around it. |
| [Textured Model 3D](textured_model_3d/README.md) | Inspect a model's material maps. |
| [Skeletal Animation 3D](skeletal_animation_3d/README.md) | Independent animation playback. |
| [Post Processing 3D](post_processing_3d/README.md) | Bloom, tone mapping, occlusion, and depth of field. |
| [Skybox 3D](skybox_3d/README.md) | Atmospheric scattering, directional sun, and procedural skies. |
| [Terrain 3D](terrain_3d/README.md) | Heightmap landscapes with chunked meshes, collision, and hot reload. |
| [Orbit Camera](orbit_camera/README.md) | Control a camera with the mouse. |
| [Camera Switching](camera_switching/README.md) | Switch between three cameras. |
| [First Person 3D](first_person_3d/README.md) | Walk, look, jump, and sprint. |
| [Third Person 3D](third_person_3d/README.md) | Capsule movement course with crouching, platforms, and an orbit camera. |
| [Audio Components](audio_components/README.md) | Distance and mixer controls. |
| [Box3D Ball Drop](box3d_balls/README.md) | Drop and roll rigid bodies. |
| [Solar System](solar_system/README.md) | Orbits and parented transforms. |

## Games

| Example | What it covers |
| --- | --- |
| [Pong](pong/README.md) | Paddles, serves, and scoring. |
| [Asteroids](asteroids/README.md) | Wrap, shoot, and split asteroids. |
| [Tanks](tanks/README.md) | Tank battles with ricocheting shells. |
| [Tetris](tetris/README.md) | Falling blocks and line clearing. |
| [Dungeon Crawler](dungeoncrawler/README.md) | Explore rooms and fight monsters. |

## Maintaining examples

Keep introductory examples focused on one feature. Put controls and live feedback
on screen, and explain setup or implementation in the example's README. Prefer
explicit engine setup over a shared helper that hides the calls being taught.

Format Odin sources with the example settings, then run the headless checks:

```powershell
odinfmt -path:examples -config:examples/odinfmt.json -w
pwsh -NoProfile -File tools/validate.ps1 -AllExamples
```
