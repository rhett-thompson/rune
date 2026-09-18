# Built-in component reference

This reference covers all **48 components** registered by
[`ecs.register_builtin_components`](../rune/ecs/registry.odin). Field names are
the scene/prefab JSON names. Coverage and JSON defaults were checked against the
registry, schemas, and live ECS parsing/serialization on 2026-09-16.

## Using components

Place component objects inside an entity's `components` map:

```json
{
  "id": "marker",
  "components": {
    "Transform": {"position": [120, 80, 0]},
    "ShapeRenderer2D": {"shape": "circle", "radius": 16},
    "Lifetime": {"seconds": 2}
  }
}
```

All built-ins are single-instance per entity except `AudioPlayer`, whose object
contains named instances. Entity `id`, `name`, `tag`, `layers`, `enabled`,
`children`, and prefab data live outside the component map. Custom registered
Odin components can share the map; they are not part of this reference.

Tables list authorable fields, including nested profile fields. **Required**
means no authored default; **Conditional** means another field determines the
requirement. Default values describe omission when loading JSON, not a
zero-initialized Odin struct. Some omitted values are internal empty strings or
maps; this does not imply that explicitly writing the empty value satisfies the
schema. Numeric values must be finite. Colors are four integer RGBA channels
from 0 to 255. Asset paths are project-relative. Durations use seconds unless
stated otherwise. Scalar/schema bounds appear in the tables; cross-field and
component dependencies appear in the accompanying text and linked guides.

For typed single-instance access, use `ecs.get`, `ecs.set`, and `ecs.add`.
Initialize with the component's default helper when available, then override
fields; supplying a typed value supplies every field. `AudioPlayer` uses named
instance accessors. Playback time, paths, contact buffers, grounded state,
controller requests, and other simulation state are not additional JSON settings.
Some runtime inspection snapshots include state fields; do not copy those fields
into authored JSON unless listed here.

Entity activation applies across components. A disabled ancestor disables its
descendants; queries skip them by default. Component-level `enabled` or `active`
fields have their narrower documented meanings. See [activation and typed
creation](entity_features.md) and [runtime lifecycle](../README.md#runtime-lifecycle).

The scene-owning loop advances supported engine systems, but attaching data does
not imply automatic gameplay: Orbit, Rotator, legacy movement, and 2D navigation
require the explicit calls described below. Advanced 3D rendering/animation uses
the optional r3d bridge. See [hot reload](../README.md#development-hot-reload) for
state preservation and [checkpoint saves](save-load.md) for opt-in persistence.

## Component index

- **Spatial data and lifetime:** [Transform](#transform), [Orbit](#orbit), [Rotator](#rotator), [Lifetime](#lifetime).
- **2D rendering and animation:** [SpriteRenderer](#spriterenderer), [SpriteAnimator](#spriteanimator), [ShapeRenderer2D](#shaperenderer2d), [TextRenderer](#textrenderer), [TilemapRenderer](#tilemaprenderer), [ParticleEmitter2D](#particleemitter2d).
- **3D rendering and environment:** [MeshRenderer](#meshrenderer), [SphereRenderer](#sphererenderer), [ModelRenderer](#modelrenderer), [ModelAnimator](#modelanimator), [Terrain](#terrain), [AmbientLight](#ambientlight), [DirectionalLight](#directionallight), [PointLight](#pointlight), [SpotLight](#spotlight), [Skybox](#skybox), [PostProcessing](#postprocessing).
- **Cameras:** [Camera2D](#camera2d), [CameraFollow2D](#camerafollow2d), [Camera3D](#camera3d), [OrbitCamera3D](#orbitcamera3d).
- **2D physics and movement:** [RigidBody2D](#rigidbody2d), [BoxCollider2D](#boxcollider2d), [CircleCollider2D](#circlecollider2d), [CapsuleCollider2D](#capsulecollider2d), [PolygonCollider2D](#polygoncollider2d), [SegmentCollider2D](#segmentcollider2d), [CharacterController2D](#charactercontroller2d), [TilemapCollider](#tilemapcollider), [TopDownController](#topdowncontroller).
- **3D physics and movement:** [RigidBody3D](#rigidbody3d), [BoxCollider](#boxcollider), [SphereCollider](#spherecollider), [CharacterController](#charactercontroller), [CharacterController3D](#charactercontroller3d).
- **Navigation:** [NavGrid2D](#navgrid2d), [NavAgent2D](#navagent2d), [NavMesh3D](#navmesh3d), [NavAgent3D](#navagent3d).
- **Interactions and triggers:** [Interactable3D](#interactable3d), [Interactor3D](#interactor3d), [Trigger3D](#trigger3d).
- **Audio:** [AudioListener](#audiolistener), [AudioPlayer](#audioplayer).

## Spatial data and lifetime

### Transform

Local position, Euler rotation in degrees, and scale. 2D rendering uses X/Y and Z rotation; 3D uses all axes. Rendering composes parent transforms; individual physics backends have their own hierarchy/rotation restrictions. A zero-initialized Odin struct has zero scale: use `ecs.default_transform()` when creating one in code.

[Guide / example](../README.md#scene-owned-rendering) · [Implementation](../rune/ecs/transform.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `position` | 3-item array of number | `[0, 0, 0]` | Local X/Y/Z position. |
| `rotation` | 3-item array of number | `[0, 0, 0]` | Rotation in degrees. |
| `scale` | 3-item array of number | `[1, 1, 1]` | Per-axis local scale. |

### Orbit

Rotates the entity's local X/Z position around its parent origin, preserving Y. The initial position supplies radius and starting angle; without a parent it orbits the world origin. Requires `Transform`. Call `ecs.update_orbits(world, dt)` from a game system; attaching the component alone does not advance it.

[Guide / example](../examples/solar_system/README.md) · [Implementation](../rune/ecs/motion.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `degrees_per_second` | number | Required | Angular speed in degrees/second; negative reverses direction. |

### Rotator

Adds rotation around the entity's local Y axis. Requires `Transform`. Call `ecs.update_rotators(world, dt)` from a game system; attaching the component alone does not advance it. Negative speed reverses the spin.

[Guide / example](../examples/solar_system/README.md) · [Implementation](../rune/ecs/motion.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `degrees_per_second` | number | Required | Angular speed in degrees/second; negative reverses direction. |

### Lifetime

Destroys the entity and its descendants after the configured simulation duration. The scene-owning loop advances it automatically; disabled entities and paused simulation suspend the timer. Zero expires on the next positive update. Explicitly setting the component restarts the timer. Elapsed time is runtime state, not an authored field.

[Guide / example](entity_features.md#lifetime) · [Implementation](../rune/ecs/lifetime.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `seconds` | number; ≥ 0 | Required | Simulation seconds before destroying this entity and its children; suspended while disabled. |

## 2D rendering and animation

### SpriteRenderer

Draws a texture through the active 2D camera and the entity hierarchy transform. An animator can supply the texture/source rectangle. A zero-size source rectangle selects the full texture; source width and height must be nonnegative. Origin is the normalized pivot. Draw order is shared with shapes, tilemaps, text, and particles.

[Guide / example](../README.md#json-sprite-scene) · [Implementation](../rune/ecs/render_components.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `texture` | string; nonempty | `""` | Project-relative texture path. |
| `origin` | 2-item array of number | `[0.5, 0.5]` | Normalized pivot. |
| `source` | 4-item array of number | `[0, 0, 0, 0]` | Texture source rectangle. Zero width or height selects the full texture. |
| `tint` | 4-item array of integer; ≥ 0; ≤ 255 | `[255, 255, 255, 255]` | RGBA color with channels from 0 through 255. |
| `flip_x` | boolean | `false` | Mirror horizontally. |
| `flip_y` | boolean | `false` | Mirror vertically. |
| `draw_order` | integer; ≥ -1000000; ≤ 1000000 | `0` | Shared 2D draw order; larger values draw later. |

### SpriteAnimator

Selects a named clip from a sprite-animation asset and drives the entity's `SpriteRenderer`. The scene loop advances playback and buffers markers before `post_animation` systems. Playback position, queued clips, and event buffers are runtime state. Sprite speed must be positive; use the playback API to pause.

[Guide / example](animation-events.md) · [Implementation](../rune/ecs/render_components.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `animation` | string; nonempty | Required | Project-relative sprite-animation asset. |
| `clip` | string; nonempty | Required | Named animation clip. |
| `autoplay` | boolean | `true` | Begin playback automatically. |
| `speed` | number; > 0 | `1` | Positive playback rate multiplier. |

### ShapeRenderer2D

Draws an untextured rectangle or circle through `Transform` and the active 2D camera. Both size and radius remain positive even when unused by the selected shape. Nonuniform scale turns circles into ellipses. Outline width is in world units and follows camera zoom, but entity scale does not multiply the line width.

[Guide / example](entity_features.md#shaperenderer2d) · [Implementation](../rune/ecs/shape_renderer_2d.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `shape` | `"rectangle"`, `"circle"` | `"rectangle"` | Geometry shape. |
| `size` | 2-item array of number; > 0 | `[32, 32]` | Full dimensions in local units. |
| `radius` | number; > 0 | `16` | Radius in world/local units as described above. |
| `origin` | 2-item array of number | `[0.5, 0.5]` | Normalized pivot. |
| `color` | 4-item array of integer; ≥ 0; ≤ 255 | `[255, 255, 255, 255]` | RGBA color. |
| `filled` | boolean | `true` | Fill the shape; false draws an outline. |
| `line_width` | number; > 0 | `1` | Outline width in world units. |
| `draw_order` | integer; ≥ -1000000; ≤ 1000000 | `0` | Shared 2D draw order; larger values draw later. |

### TextRenderer

Draws font-backed text through `Transform` and the active 2D camera, with the shared 2D draw order. Font paths are project-relative. Origin is a normalized text pivot. Empty text is valid; font is required. Use UI drawing for text that should stay at native window resolution.

[Guide / example](../README.md#scene-text) · [Implementation](../rune/ecs/render_components.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `text` | string | Required | Text content. |
| `font` | string; nonempty | Required | Project-relative font path. |
| `font_size` | number; > 0 | `20` | Text size in world units. |
| `spacing` | number | `0` | Extra glyph spacing. |
| `color` | 4-item array of integer; ≥ 0; ≤ 255 | `[255, 255, 255, 255]` | RGBA color with channels from 0 through 255. |
| `origin` | 2-item array of number | `[0, 0]` | Normalized pivot. |
| `draw_order` | integer; ≥ -1000000; ≤ 1000000 | `0` | Shared 2D draw order; larger values draw later. |

### TilemapRenderer

Draws a row-major tile grid through `Transform`. Supply `tileset`, or both `texture` and `tile_size`; a tileset provides atlas metadata. Grid cells are tile indices; `-1` is empty. Add `TilemapCollider` for solid tile IDs. Cached tile maps, dimensions, and asset revisions are runtime-derived data.

[Guide / example](../README.md#2d-tilemaps) · [Implementation](../rune/ecs/render_components.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `tileset` | string; nonempty | Conditional; see above | Project-relative tileset JSON asset. |
| `texture` | string; nonempty | Conditional; see above | Project-relative texture path. |
| `tile_size` | 2-item array of number; > 0 | Conditional; see above | Atlas cell width and height. |
| `draw_order` | integer; ≥ -1000000; ≤ 1000000 | `0` | Shared 2D draw order; larger values draw later. |
| `grid` | array of array of integer; ≥ -1 | Required | Rows of tile indices; -1 is empty. |

### ParticleEmitter2D

World-space CPU particles emitted from the entity transform. Existing particles remain independent of later emitter movement. The scene loop updates them automatically; Odin can request bursts even with `emitting: false`. Capacity or seed changes reset the pool. Lifetime/speed pairs are minimum and maximum, with maximum at least minimum.

[Guide / example](particles.md) · [Implementation](../rune/ecs/particles.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `max_particles` | integer; ≥ 1; ≤ 65536 | `256` | Maximum live particles. |
| `emitting` | boolean | `true` | Continuous emission. False lets existing particles finish; Odin bursts still work. |
| `rate` | number; ≥ 0; ≤ 100000 | `30` | Particles per simulation second. |
| `lifetime` | 2-item array of number; > 0 | `[0.5, 1]` | Minimum/maximum lifetime in seconds; maximum must be >= minimum. |
| `speed` | 2-item array of number; ≥ 0 | `[40, 100]` | Minimum/maximum speed in world units per second; maximum must be >= minimum. |
| `angle` | number | `-90` | Degrees clockwise from +X; -90 points up. Transform Z rotation is added. |
| `spread` | number; ≥ 0; ≤ 360 | `30` | Full cone angle in degrees, centered on angle. |
| `gravity` | 2-item array of number | `[0, 0]` | World-space acceleration in units per second squared. |
| `start_size` | number; ≥ 0 | `8` | Initial diameter in world units. |
| `end_size` | number; ≥ 0 | `0` | Final diameter; interpolated linearly over lifetime. |
| `start_color` | 4-item array of integer; ≥ 0; ≤ 255 | `[255, 220, 120, 255]` | RGBA color with channels from 0 through 255. |
| `end_color` | 4-item array of integer; ≥ 0; ≤ 255 | `[255, 80, 30, 0]` | RGBA color with channels from 0 through 255. |
| `texture` | string | `""` | Optional cached texture drawn as a square. Empty draws circles. |
| `additive` | boolean | `false` | Use additive blending. |
| `draw_order` | integer; ≥ -1000000; ≤ 1000000 | `0` | Shared 2D draw order; larger values draw later. |
| `seed` | integer; ≥ 0; ≤ 4294967295 | `1` | Per-emitter random seed; zero uses 1. Changing seed resets particles. |

## 3D rendering and environment

### MeshRenderer

Draws a built-in cube or plane through the 3D rendering path. Set `primitive` explicitly: omission leaves an empty value and draws neither shape. Transform sets pose and dimensions. Optional material assets enable the r3d material pipeline; without a material the component color supplies the surface color.

[Guide / example](../README.md#asset-backed-3d-models) · [Implementation](../rune/ecs/render_components.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `primitive` | `"cube"`, `"plane"` | `""` | Built-in geometry; choose cube or plane explicitly. |
| `color` | 4-item array of integer; ≥ 0; ≤ 255 | `[255, 255, 255, 255]` | RGBA color with channels from 0 through 255. |
| `material` | string; nonempty | `""` | Optional project-relative material asset; omit for no override. |
| `shadows` | boolean | `true` | Enable shadow casting for geometry, or shadows for this light. |

### SphereRenderer

Draws a sphere with the given local radius, multiplied by transform scale. Optional material assets use the r3d material pipeline. Rendering and collision are separate: add a collider when the sphere should interact with physics.

[Guide / example](../README.md#asset-backed-3d-models) · [Implementation](../rune/ecs/render_components.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `radius` | number; > 0 | `1` | Radius in world/local units as described above. |
| `color` | 4-item array of integer; ≥ 0; ≤ 255 | `[255, 255, 255, 255]` | RGBA color with channels from 0 through 255. |
| `material` | string; nonempty | `""` | Optional project-relative material asset; omit for no override. |
| `shadows` | boolean | `true` | Enable shadow casting for geometry, or shadows for this light. |

### ModelRenderer

Loads a project-relative model asset and renders it through the entity transform. `material` is the fallback override; entries in `materials` override individual zero-based imported material slots. Omit overrides to retain imported materials. Keys are nonnegative integer strings within the signed 32-bit slot range.

[Guide / example](../examples/textured_model_3d/README.md) · [Implementation](../rune/ecs/render_components.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `model` | string; nonempty | Required | Project-relative model asset. |
| `tint` | 4-item array of integer; ≥ 0; ≤ 255 | `[255, 255, 255, 255]` | RGBA color with channels from 0 through 255. |
| `material` | string; nonempty | `""` | Optional project-relative material asset; omit for no override. |
| `materials` | object | `{}` | Material overrides keyed by zero-based raylib material slot index. |

### ModelAnimator

Controls independent skeletal playback for the entity's `ModelRenderer` through the optional r3d bridge. Clip names are case-sensitive embedded names or registered external-animation aliases; empty chooses the first imported clip. Negative speed plays backward; zero is invalid. `blend_time` controls transitions. Gameplay consumes marker events after the bridge animation update.

[Guide / example](model-animation.md) · [Implementation](../rune/ecs/model_animation.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `events` | string | `""` | Project-relative skeletal marker track JSON; empty disables markers. |
| `clip` | string | `""` | Case-sensitive embedded clip name or registered external-animation alias; empty uses the first imported clip. |
| `blend_time` | number; ≥ 0 | `0` | Blend duration in seconds when changing skeletal clips. |
| `speed` | number; ≠ 0 | `1` | Nonzero playback rate multiplier; negative plays backward. |
| `loop` | boolean | `true` | Repeat the clip. |
| `autoplay` | boolean | `true` | Begin playback automatically. |

### Terrain

References a `.terrain.json` asset containing heightmap, material, and chunk settings. Requires `Transform`; keep terrain on its own entity without another 3D collider, rigid body, or character controller. Rendering and static triangle collision use the same height samples. The scene loop synchronizes assets, including during pause. See the terrain guide for supported transforms and asset fields.

[Guide / example](terrain.md) · [Implementation](../rune/ecs/terrain.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `asset` | string; nonempty | Required | Project-relative .terrain.json path. |
| `collision` | boolean | `true` | Generate terrain collision. |
| `shadows` | boolean | `true` | Enable shadow casting for geometry, or shadows for this light. |
| `friction` | number; ≥ 0 | `0.8` | Nonnegative surface friction. |

### AmbientLight

Sets scene ambient color and intensity for lit 3D materials. No position is needed. Prefer one scene ambient light. This controls lighting independently of the sky background.

[Guide / example](../README.md#asset-backed-3d-models) · [Implementation](../rune/ecs/light.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `color` | 4-item array of integer; ≥ 0; ≤ 255 | `[255, 255, 255, 255]` | RGBA color with channels from 0 through 255. |
| `intensity` | number; ≥ 0 | `0.2` | Light/effect strength. |

### DirectionalLight

Provides a directional 3D light. Direction is an explicit vector, independent of entity position. `range` sets the camera-centered directional shadow radius. Shadow controls apply through r3d; enable shadows on both relevant lights and shadow-casting geometry.

[Guide / example](../README.md#asset-backed-3d-models) · [Implementation](../rune/ecs/light.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `direction` | 3-item array of number | `[-0.35, -1, -0.45]` | Explicit light direction vector. |
| `color` | 4-item array of integer; ≥ 0; ≤ 255 | `[255, 255, 255, 255]` | RGBA color with channels from 0 through 255. |
| `intensity` | number; ≥ 0 | `1` | Light/effect strength. |
| `range` | number; > 0 | `16` | Directional shadow radius around the camera. |
| `specular` | number; ≥ 0 | `1` | Specular contribution multiplier. |
| `shadows` | boolean | `false` | Enable shadow casting for geometry, or shadows for this light. |
| `shadow_softness` | number; ≥ 0 | `0` | Shadow softness. |
| `shadow_opacity` | number; ≥ 0 | `1` | Shadow opacity multiplier. |
| `shadow_depth_bias` | number; ≥ 0 | `0` | Shadow depth bias. |
| `shadow_slope_bias` | number; ≥ 0 | `0` | Shadow slope bias. |

### PointLight

Provides a local omnidirectional light at the entity transform position. Range is in world units. Specular and shadow settings use the same controls as a directional light; the active r3d light budget still applies.

[Guide / example](../README.md#asset-backed-3d-models) · [Implementation](../rune/ecs/light.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `color` | 4-item array of integer; ≥ 0; ≤ 255 | `[255, 255, 255, 255]` | RGBA color with channels from 0 through 255. |
| `intensity` | number; ≥ 0 | `1` | Light/effect strength. |
| `range` | number; > 0 | `5` | Light reach in world units. |
| `specular` | number; ≥ 0 | `1` | Specular contribution multiplier. |
| `shadows` | boolean | `false` | Enable shadow casting for geometry, or shadows for this light. |
| `shadow_softness` | number; ≥ 0 | `0` | Shadow softness. |
| `shadow_opacity` | number; ≥ 0 | `1` | Shadow opacity multiplier. |
| `shadow_depth_bias` | number; ≥ 0 | `0` | Shadow depth bias. |
| `shadow_slope_bias` | number; ≥ 0 | `0` | Shadow slope bias. |

### SpotLight

Provides a cone light at the entity transform position with an explicit direction. Inner/outer cone angles are degrees; outer must be at least inner. Direction is not derived from transform rotation. Range is in world units.

[Guide / example](../README.md#asset-backed-3d-models) · [Implementation](../rune/ecs/light.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `direction` | 3-item array of number | `[0, -1, 0]` | Explicit light direction vector. |
| `color` | 4-item array of integer; ≥ 0; ≤ 255 | `[255, 255, 255, 255]` | RGBA color with channels from 0 through 255. |
| `intensity` | number; ≥ 0 | `1` | Light/effect strength. |
| `range` | number; > 0 | `8` | Light reach in world units. |
| `inner_angle` | number; > 0 | `18` | Inner cone angle in degrees. |
| `outer_angle` | number; > 0 | `32` | Outer cone angle in degrees; at least inner_angle. |
| `specular` | number; ≥ 0 | `1` | Specular contribution multiplier. |
| `shadows` | boolean | `false` | Enable shadow casting for geometry, or shadows for this light. |
| `shadow_softness` | number; ≥ 0 | `0` | Shadow softness. |
| `shadow_opacity` | number; ≥ 0 | `1` | Shadow opacity multiplier. |
| `shadow_depth_bias` | number; ≥ 0 | `0` | Shadow depth bias. |
| `shadow_slope_bias` | number; ≥ 0 | `0` | Shadow slope bias. |

### Skybox

Renders a 3D background through r3d; no `Transform` is required and it does not replace scene lighting. An enabled profile on the active camera wins, otherwise the lowest-handle enabled non-camera entity wins. Cubemap mode requires a nonempty texture; atmospheric mode requires `atmosphere.sun` to reference a directional light. Resolution must be a power of two from 16 to 2048. Nested settings retain defaults when omitted.

[Guide / example](skybox.md) · [Implementation](../rune/ecs/skybox.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `enabled` | boolean | `true` | Enable this feature/profile. |
| `mode` | `"procedural"`, `"cubemap"`, `"atmospheric"` | `"procedural"` | Background generation/source mode. |
| `texture` | string | `""` | Project-relative texture path. |
| `layout` | `"auto_detect"`, `"line_vertical"`, `"line_horizontal"`, `"cross_three_by_four"`, `"cross_four_by_three"`, `"panorama"` | `"auto_detect"` | Cubemap image arrangement; panorama is equirectangular. |
| `rotation` | 3-item array of number | `[0, 0, 0]` | Euler angles in degrees. Ignored by the world-aligned atmospheric mode. |
| `energy` | number; ≥ 0 | `1` | Overall background brightness multiplier. |
| `resolution` | `16`, `32`, `64`, `128`, `256`, `512`, `1024`, `2048` | `256` | Generated cubemap face size in pixels. |
| `atmosphere` | object | Defaults below | World-aligned atmospheric scattering settings. |
| `atmosphere.sun` | string | `""` | Scene entity ID with a DirectionalLight. |
| `atmosphere.moon` | string | `""` | Optional DirectionalLight entity ID; empty disables the moon. |
| `atmosphere.moon_size` | number; ≥ 0.1; ≤ 20 | `0.52` | Full moon angular diameter in degrees. |
| `atmosphere.night_color` | 4-item array of integer; ≥ 0; ≤ 255 | `[30, 45, 85, 255]` | RGBA tint of the night background fill. |
| `atmosphere.night_energy` | number; ≥ 0 | `0.3` | Night background fill, fading out at sunrise. Zero disables the fill. |
| `atmosphere.rayleigh` | number; ≥ 0; ≤ 10 | `1` | Rayleigh scattering strength multiplier. |
| `atmosphere.mie` | number; ≥ 0; ≤ 10 | `1` | Mie scattering strength multiplier. |
| `atmosphere.mie_anisotropy` | number; ≥ 0; ≤ 0.95 | `0.8` | Directional concentration of Mie scattering. |
| `atmosphere.sun_size` | number; ≥ 0.1; ≤ 20 | `0.53` | Sun angular diameter in degrees. |
| `atmosphere.ground_color` | 4-item array of integer; ≥ 0; ≤ 255 | `[45, 53, 59, 255]` | RGBA ground tint for atmospheric mode. |
| `procedural` | object | Defaults below | Gradient sky and artistic sun settings. |
| `procedural.sky_top_color` | 4-item array of integer; ≥ 0; ≤ 255 | `[98, 116, 140, 255]` | RGBA sky color toward the zenith. |
| `procedural.sky_horizon_color` | 4-item array of integer; ≥ 0; ≤ 255 | `[165, 167, 171, 255]` | RGBA sky color at the horizon. |
| `procedural.sky_horizon_curve` | number; ≥ 0.01; ≤ 1 | `0.15` | Shape of the sky gradient transition near the horizon. |
| `procedural.sky_energy` | number; ≥ 0 | `1` | Sky-gradient brightness multiplier. |
| `procedural.ground_bottom_color` | 4-item array of integer; ≥ 0; ≤ 255 | `[51, 43, 34, 255]` | RGBA ground color toward the nadir. |
| `procedural.ground_horizon_color` | 4-item array of integer; ≥ 0; ≤ 255 | `[165, 167, 171, 255]` | RGBA ground color at the horizon. |
| `procedural.ground_horizon_curve` | number; ≥ 0.01; ≤ 1 | `0.02` | Shape of the ground gradient transition. |
| `procedural.ground_energy` | number; ≥ 0 | `1` | Ground-gradient brightness multiplier. |
| `procedural.sun_enabled` | boolean | `true` | Render the procedural sun disk and halo. False leaves only the sky and ground gradients. |
| `procedural.sun_direction` | 3-item array of number | `[-1, -1, -1]` | Nonzero directional vector for the artistic sun. |
| `procedural.sun_color` | 4-item array of integer; ≥ 0; ≤ 255 | `[255, 255, 255, 255]` | RGBA sun tint. |
| `procedural.sun_size` | number; ≤ 180; > 0 | `1.5` | Sun angular size in degrees. |
| `procedural.sun_curve` | number; ≥ 0.01; ≤ 1 | `0.15` | Shape of the sun disk/halo transition. |
| `procedural.sun_energy` | number; ≥ 0 | `1` | Sun brightness multiplier. |

### PostProcessing

A complete r3d 3D effects profile; no `Transform` required. An enabled profile on the active camera takes precedence over the lowest-handle enabled non-camera profile. Profiles do not merge and do not affect later 2D/UI drawing. Defaults enable FXAA and linear tone mapping while disabling optional effects. Fog end must exceed start, and maximum exposure EV must be at least minimum EV. Nested settings retain defaults.

[Guide / example](post-processing.md) · [Implementation](../rune/ecs/post_processing.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `enabled` | boolean | `true` | Enable this feature/profile. |
| `anti_aliasing` | `"disabled"`, `"fxaa"`, `"smaa"` | `"fxaa"` | Screen-space anti-aliasing mode. |
| `bloom` | object | Defaults below | Glow around bright areas. |
| `bloom.mode` | `"disabled"`, `"mix"`, `"additive"`, `"screen"` | `"disabled"` | Bloom compositing mode. |
| `bloom.levels` | number; ≥ 0; ≤ 1 | `0.5` | Mipmap spread factor; larger values create a wider glow. |
| `bloom.intensity` | number; ≥ 0 | `0.05` | Bloom strength multiplier. |
| `bloom.threshold` | number; ≥ 0 | `0` | Minimum brightness that contributes to bloom. |
| `bloom.soft_threshold` | number; ≥ 0; ≤ 1 | `0.5` | Softness of the brightness cutoff. |
| `bloom.filter_radius` | number; ≥ 0 | `1` | Upsampling blur radius. |
| `tonemap` | object | Defaults below | HDR-to-display tone mapping and exposure. |
| `tonemap.mode` | `"linear"`, `"reinhard"`, `"filmic"`, `"aces"`, `"agx"` | `"linear"` | Tone-mapping curve. |
| `tonemap.exposure` | number; ≥ 0 | `1` | Exposure multiplier. |
| `tonemap.white` | number; > 0 | `1` | White-point setting. |
| `color` | object | Defaults below | Final brightness, contrast, and saturation controls. |
| `color.brightness` | number; ≥ 0 | `1` | Brightness multiplier. |
| `color.contrast` | number; ≥ 0 | `1` | Contrast multiplier. |
| `color.saturation` | number; ≥ 0 | `1` | Saturation multiplier; zero removes color. |
| `ssao` | object | Defaults below | Screen-space ambient occlusion. |
| `ssao.enabled` | boolean | `false` | Enable this feature/profile. |
| `ssao.sample_count` | integer; ≥ 1; ≤ 64 | `16` | Number of occlusion samples. |
| `ssao.intensity` | number; ≥ 0 | `1` | Occlusion strength. |
| `ssao.power` | number; > 0 | `1` | Exponent controlling occlusion darkening. |
| `ssao.max_radius` | number; ≤ 1; > 0 | `0.2` | Sampling radius cap as a fraction of screen height. |
| `ssao.radius` | number; > 0 | `1` | World-space sampling radius. |
| `ssao.bias` | number; ≥ 0 | `0.03` | World-space depth bias against self-occlusion. |
| `ssil` | object | Defaults below | Screen-space indirect light with ambient occlusion. |
| `ssil.enabled` | boolean | `false` | Enable this feature/profile. |
| `ssil.sample_count` | integer; ≥ 1; ≤ 64 | `16` | Number of lighting/occlusion samples. |
| `ssil.gi_intensity` | number; ≥ 0 | `1` | Indirect light strength. |
| `ssil.ao_intensity` | number; ≥ 0 | `1` | Occlusion strength. |
| `ssil.ao_power` | number; > 0 | `1` | Exponent controlling occlusion darkening. |
| `ssil.max_radius` | number; ≤ 1; > 0 | `0.2` | Sampling radius cap as a fraction of screen height. |
| `ssil.radius` | number; > 0 | `4` | World-space sampling radius. |
| `ssil.bias` | number; ≥ 0 | `0.03` | World-space depth bias against self-occlusion. |
| `ssgi` | object | Defaults below | Screen-space global illumination. |
| `ssgi.enabled` | boolean | `false` | Enable this feature/profile. |
| `ssgi.slice_count` | integer; ≥ 1; ≤ 32 | `4` | Sample directions per pixel; higher costs more. |
| `ssgi.edge_fade` | number; ≥ 0; ≤ 1 | `0.1` | Fade indirect light near screen boundaries. |
| `ssgi.distance_falloff` | number; ≥ 0 | `1` | Distance attenuation; higher values shorten indirect light reach. |
| `ssgi.normal_rejection` | number; ≥ 0; ≤ 1 | `0` | Reject light from behind surfaces; zero disables rejection. |
| `ssgi.intensity` | number; ≥ 0 | `1` | Indirect lighting brightness. |
| `ssgi.denoise_steps` | integer; ≥ 0; ≤ 8 | `4` | Number of denoising passes. |
| `ssr` | object | Defaults below | Screen-space reflections. |
| `ssr.enabled` | boolean | `false` | Enable this feature/profile. |
| `ssr.max_ray_steps` | integer; ≥ 1; ≤ 256 | `32` | Maximum ray-marching steps. |
| `ssr.binary_steps` | integer; ≥ 0; ≤ 32 | `4` | Hit refinement steps. |
| `ssr.step_size` | number; > 0 | `0.125` | Distance per ray step. |
| `ssr.thickness` | number; > 0 | `0.2` | Depth tolerance for a reflection hit. |
| `ssr.max_distance` | number; > 0 | `4` | Maximum reflection ray distance. |
| `ssr.edge_fade` | number; ≥ 0; ≤ 1 | `0.25` | Screen-edge reflection fade setting. |
| `fog` | object | Defaults below | Distance fog; end must exceed start. |
| `fog.mode` | `"disabled"`, `"linear"`, `"exp2"`, `"exp"` | `"disabled"` | Disabled, linear, or exponential distance fog. |
| `fog.color` | 4-item array of integer; ≥ 0; ≤ 255 | `[255, 255, 255, 255]` | RGBA color. |
| `fog.start` | number; ≥ 0 | `1` | Camera distance where linear fog begins. |
| `fog.end` | number; ≥ 0 | `50` | Camera distance where linear fog reaches full density. |
| `fog.density` | number; ≥ 0 | `0.05` | Thickness factor for exponential fog. |
| `fog.sky_affect` | number; ≥ 0; ≤ 1 | `0.5` | Fog influence on the sky, from zero to full. |
| `dof` | object | Defaults below | Depth of field outside the focal plane. |
| `dof.enabled` | boolean | `false` | Enable this feature/profile. |
| `dof.focus_point` | number; > 0 | `10` | Focus distance from the camera in world units. |
| `dof.focus_scale` | number; > 0 | `1` | Depth of the focused range; lower values make it shallower. |
| `dof.near_scale` | number; ≥ 0 | `1` | Near-blur strength; zero disables near blur. |
| `dof.max_blur_size` | number; ≥ 0; ≤ 64 | `20` | Maximum blur radius. |
| `auto_exposure` | object | Defaults below | Luminance-driven exposure; max_ev must be at least min_ev. Uses one temporal history. |
| `auto_exposure.enabled` | boolean | `false` | Enable this feature/profile. |
| `auto_exposure.min_ev` | number; ≥ -32; ≤ 32 | `-1` | Minimum measured luminance in EV stops relative to middle gray. |
| `auto_exposure.max_ev` | number; ≥ -32; ≤ 32 | `1` | Maximum measured luminance in EV stops relative to middle gray. |
| `auto_exposure.exposure_compensation` | number; ≥ -32; ≤ 32 | `0` | Exposure bias in stops; +1 is one stop brighter. |
| `auto_exposure.adaptation_to_bright` | number; > 0 | `0.5` | Time constant in seconds for brightening scenes; lower is faster. |
| `auto_exposure.adaptation_to_dark` | number; > 0 | `1` | Time constant in seconds for darkening scenes; lower is faster. |

## Cameras

### Camera2D

Uses the entity transform X/Y position as the world target. Offset is the canvas point at which that target appears. Rotation is in degrees and zoom must be positive. Set `active: true` to select the view; the default is inactive. Keep only one active camera of each kind.

[Guide / example](display.md) · [Implementation](../rune/ecs/camera.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `offset` | 2-item array of number | `[0, 0]` | Canvas point where the world target appears. |
| `zoom` | number; > 0 | `1` | Positive view zoom. |
| `rotation` | number | `0` | Rotation in degrees. |
| `active` | boolean | `false` | Select this camera/listener. |

### CameraFollow2D

Moves a `Camera2D` entity's transform toward a target entity with a transform. Target is a stable scene ID string. Dead-zone dimensions and optional bounds are world units. Smoothing zero snaps immediately; positive values use exponential smoothing. Bounds are `[min_x, min_y, max_x, max_y]` with strict positive extents. The scene loop updates following automatically.

[Guide / example](../README.md#2d-tilemaps) · [Implementation](../rune/ecs/camera.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `target` | string; nonempty | Required | Scene entity ID to follow. |
| `dead_zone` | 2-item array of number; ≥ 0 | `[0, 0]` | World-space width/height allowed before following. |
| `smoothing` | number; ≥ 0 | `0` | Exponential follow rate; zero snaps. |
| `bounds` | 4-item array of number | Omitted | Optional world bounds [min_x, min_y, max_x, max_y]. |

### Camera3D

Uses the entity transform position as the camera position. Target and up explicitly define the view; transform rotation does not replace them. FOV is vertical degrees. Set `active: true` to select the view; the default is inactive. The camera-switching example changes active cameras in Odin.

[Guide / example](../examples/camera_switching/README.md) · [Implementation](../rune/ecs/camera.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `target` | 3-item array of number | `[0, 0, 0]` | Camera target position. |
| `up` | 3-item array of number | `[0, 1, 0]` | Camera up vector. |
| `fovy` | number; > 0 | `45` | Vertical field of view in degrees. |
| `active` | boolean | `false` | Select this camera/listener. |

### OrbitCamera3D

Drives `Transform` and `Camera3D` around a target. The scene-owning loop updates it automatically; callback loops call `rune.update_orbit_cameras_3d`. Held manual input controls orbit; panning takes precedence over orbit and automatic rotation. Empty pan action disables panning. Minimum pitch/distance must not exceed their maxima; initial pitch and distance are clamped to the configured range.

[Guide / example](../README.md#orbit-camera) · [Implementation](../rune/ecs/camera.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `target` | 3-item array of number | `[0, 0, 0]` | Camera target position. |
| `yaw` | number | `0` | Orbit azimuth in degrees. |
| `pitch` | number | `25` | Orbit elevation in degrees. |
| `distance` | number; > 0 | `8` | Distance to the orbit target. |
| `min_pitch` | number | `-80` | Lower pitch limit in degrees. |
| `max_pitch` | number | `80` | Upper pitch limit in degrees. |
| `min_distance` | number; > 0 | `1` | Minimum distance. |
| `max_distance` | number; > 0 | `100` | Maximum distance. |
| `auto_yaw_speed` | number | `0` | Automatic yaw speed in degrees/second. |
| `manual_action` | string | `"orbit_camera"` | Held action enabling manual orbit. |
| `yaw_axis` | string | `"orbit_x"` | Input axis for horizontal orbit. |
| `pitch_axis` | string | `"orbit_y"` | Input axis for vertical orbit. |
| `zoom_axis` | string | `"zoom"` | Input axis for zoom. |
| `pan_action` | string | `""` | Held action enabling camera-plane panning. Empty disables panning; panning takes priority over orbit rotation. |
| `pan_x_axis` | string | `"pan_x"` | Input axis for horizontal pan. |
| `pan_y_axis` | string | `"pan_y"` | Input axis for vertical pan. |
| `pan_sensitivity` | number; > 0 | `0.0015` | World units per input unit per unit of camera distance. Use raw mouse deltas for drag-to-pan. |
| `orbit_sensitivity` | number; > 0 | `0.35` | Degrees per orbit input unit. |
| `zoom_sensitivity` | number; > 0 | `1` | Distance per zoom input unit. |

## 2D physics and movement

### RigidBody2D

Box2D body settings. Requires a transform and a supported 2D collider for useful collision. Simulation runs at fixed 60 Hz; velocity is world units/second and gravity scale multiplies the backend's downward gravity. `grounded` is runtime state and is not a JSON field. Use fixed-update callbacks to drive physics.

[Guide / example](physics.md) · [Implementation](../rune/ecs/physics_2d.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `velocity` | 2-item array of number | `[0, 0]` | Initial linear velocity in world units/second. |
| `gravity_scale` | number; ≥ 0 | `1` | Multiplier on backend gravity. |
| `type` | `"dynamic"`, `"kinematic"`, `"static"` | `"dynamic"` | Native body motion type. |

### BoxCollider2D

A centered 2D box with local offset and positive dimensions, scaled by the entity transform. Without a rigid body it is static. `one_way` exposes the horizontal top to the platformer controller and cannot be combined with a sensor. Native collision does not follow the rendering hierarchy/rotation; see the physics guide.

[Guide / example](physics.md) · [Implementation](../rune/ecs/physics_2d.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `offset` | 2-item array of number | `[0, 0]` | Local geometry offset unless described otherwise. |
| `size` | 2-item array of number | `[16, 16]` | Full dimensions in local units. |
| `is_sensor` | boolean | `false` | Report overlaps without solid collision response. |
| `one_way` | boolean | `false` | Collide only with the horizontal top from above; cannot be combined with is_sensor. |

### CircleCollider2D

A 2D circle with local offset and positive radius. Without a rigid body it is static. Multiple supported collider types can share a body. Sensors report overlaps without solid response. Offset and radius follow the entity-local scale rules in the physics guide.

[Guide / example](physics.md) · [Implementation](../rune/ecs/physics_2d.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `offset` | 2-item array of number | `[0, 0]` | Local geometry offset unless described otherwise. |
| `radius` | number; > 0 | `8` | Radius in world/local units as described above. |
| `is_sensor` | boolean | `false` | Report overlaps without solid collision response. |

### CapsuleCollider2D

A vertical or horizontal capsule. Height is the total tip-to-tip extent, so `height >= 2 * radius`. Local offset places it relative to `Transform`. A `CharacterController2D` needs a vertical, nonsensor capsule and a dynamic `RigidBody2D`.

[Guide / example](physics.md) · [Implementation](../rune/ecs/capsule_collider_2d.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `radius` | number; > 0 | `8` | Radius in world/local units as described above. |
| `height` | number; > 0 | `32` | Total height, including capsule caps. |
| `axis` | `"vertical"`, `"horizontal"` | `"vertical"` | Capsule axis. |
| `offset` | 2-item array of number | `[0, 0]` | Local geometry offset unless described otherwise. |
| `is_sensor` | boolean | `false` | Report overlaps without solid collision response. |

### PolygonCollider2D

A convex outline of 3–8 ordered perimeter vertices, plus a local offset. Vertices must form a nondegenerate, non-self-intersecting convex polygon; either winding is accepted. It shares body, sensor, filtering, and query behavior with the other native 2D colliders.

[Guide / example](physics.md) · [Implementation](../rune/ecs/polygon_collider_2d.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `vertices` | array of 2-item array of number; at least 3 items; at most 8 items | Required | Ordered convex perimeter vertices. |
| `offset` | 2-item array of number | `[0, 0]` | Local geometry offset unless described otherwise. |
| `is_sensor` | boolean | `false` | Report overlaps without solid collision response. |

### SegmentCollider2D

A two-sided edge with distinct local endpoints. Optional one-way collision requires a horizontal segment and cannot be combined with a sensor. Offset and scale use the same rules as the other 2D colliders.

[Guide / example](physics.md) · [Implementation](../rune/ecs/segment_collider_2d.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `start` | 2-item array of number | Required | First local endpoint. |
| `end` | 2-item array of number | Required | Second local endpoint. |
| `offset` | 2-item array of number | `[0, 0]` | Local geometry offset unless described otherwise. |
| `is_sensor` | boolean | `false` | Report overlaps without solid collision response. |
| `one_way` | boolean | `false` | Collide only with the horizontal top from above; cannot be combined with is_sensor. |

### CharacterController2D

Fixed-step platformer motor. Requires `Transform`, a dynamic `RigidBody2D`, and a vertical nonsensor `CapsuleCollider2D`. Gameplay sends move/jump/release/crouch/drop/wall/dash requests through Odin APIs; component data tunes the motor. Zero step height, wall-slide speed, or dash speed disables the corresponding optional behavior. Runtime state is queried separately.

[Guide / example](character-controller-2d.md) · [Implementation](../rune/ecs/character_controller_2d.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `move_speed` | number; ≥ 0 | `200` | Maximum ground movement speed in units/second. |
| `acceleration` | number; > 0 | `1600` | Ground acceleration in units/second squared. |
| `air_acceleration` | number; ≥ 0 | `800` | Air steering acceleration in units/second squared. |
| `gravity` | number; > 0 | `1200` | Downward acceleration in units/second squared. |
| `jump_speed` | number; ≥ 0 | `460` | Upward launch speed; zero disables ground/coyote jumps. |
| `max_fall_speed` | number; > 0 | `900` | Terminal downward speed. |
| `max_slope_angle` | number; ≥ 0; < 89 | `45` | Walkable slope limit in degrees. |
| `ground_snap_distance` | number; ≥ 0 | `8` | Maximum downward ground snap. |
| `coyote_time` | number; ≥ 0; ≤ 1 | `0.1` | Jump grace period after leaving support, in seconds. |
| `jump_buffer_time` | number; ≥ 0; ≤ 1 | `0.1` | Queued jump lifetime in seconds. |
| `drop_speed` | number; > 0 | `60` | Downward speed for dropping through support. |
| `drop_time` | number; ≥ 0; ≤ 1 | `0.15` | Support-ignore duration in seconds. |
| `crouch_height` | number; ≥ 0 | `20` | Local crouched height, clamped to capsule diameter and standing height. Zero disables crouching. |
| `crouch_speed` | number; ≥ 0 | `100` | Horizontal target speed while crouched, relative to supporting platform. |
| `step_height` | number; ≥ 0 | `0` | Maximum grounded step-up in world units. Zero disables step assistance. |
| `dash_speed` | number; ≥ 0 | `0` | Horizontal dash speed relative to platform motion. Zero disables dashing. |
| `dash_duration` | number; ≤ 1; > 0 | `0.15` | Seconds per dash segment, rounded up to whole fixed steps. |
| `dash_cooldown` | number; ≥ 0 | `0.4` | Recovery after the chain finishes, expires, or is canceled. |
| `dash_chain_count` | integer; ≥ 1; ≤ 32 | `1` | Maximum dashes per chain, including the first. Each requires a press. |
| `dash_chain_window` | number; ≥ 0; ≤ 1 | `0.15` | Seconds after a dash to request the next in its chain. Zero allows only a request queued during the dash. |
| `dash_on_ground` | boolean | `true` | Allow starting a dash segment while grounded. |
| `dash_in_air` | boolean | `true` | Allow starting a dash segment while airborne. |
| `dash_gravity_scale` | number; ≥ 0 | `0` | Airborne dash gravity multiplier. Zero holds vertical velocity at inherited platform velocity; positive values retain vertical momentum. |
| `wall_slide_speed` | number; ≥ 0 | `0` | Maximum downward speed relative to a vertical wall while pressing toward it. Zero disables sliding. |
| `wall_jump_speed_x` | number; ≥ 0 | `0` | Horizontal wall-jump speed away from the wall. Both wall jump speeds must be positive to enable wall jumping. |
| `wall_jump_speed_y` | number; ≥ 0 | `0` | Upward wall-jump speed relative to wall velocity. Zero disables wall jumping. |
| `wall_jump_lock_time` | number; ≥ 0; ≤ 1 | `0.15` | Seconds of suspended horizontal steering after a wall jump. Zero restores immediate air control. |
| `jump_cut_multiplier` | number; ≥ 0; ≤ 1 | `0.5` | Remaining upward jump velocity retained on release, relative to takeoff platform velocity. One disables cutting. |

### TilemapCollider

Marks tile indices in the same entity's `TilemapRenderer` as solid for tilemap movement. Requires at least one nonnegative solid index. This is separate from native Box2D colliders and physics queries. Tile-specific collision rectangles may come from the tileset.

[Guide / example](../README.md#2d-tilemaps) · [Implementation](../rune/ecs/tilemap_physics.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `solid_tiles` | array of integer; ≥ 0; at least 1 items; unique items | Required | Nonempty set of solid tile IDs. |

### TopDownController

Axis-separated X/Y movement against solid tilemaps. Requires `Transform` and positive size dimensions. Gameplay calls `ecs.move_top_down(world, entity, delta)` with a displacement; use `speed * dt` when constructing that delta. The component does not read input or move automatically, and is separate from Box2D.

[Guide / example](../examples/tilemap_2d/README.md) · [Implementation](../rune/ecs/tilemap_physics.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `size` | 2-item array of number | `[16, 16]` | Full dimensions in local units. |
| `speed` | number; > 0 | `180` | Suggested movement speed for game code, in units/second. |

## 3D physics and movement

### RigidBody3D

Box3D body configuration, normally paired with `Transform` and `BoxCollider` or `SphereCollider`. Velocity is world units/second; angular velocity is radians/second. The scene loop advances fixed 60 Hz physics. Do not share movement ownership with `CharacterController3D`, terrain, or a directly driven navigation agent.

[Guide / example](physics.md) · [Implementation](../rune/ecs/physics_3d.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `velocity` | 3-item array of number | `[0, 0, 0]` | Initial linear velocity in world units/second. |
| `angular_velocity` | 3-item array of number | `[0, 0, 0]` | Initial angular velocity in radians/second. |
| `gravity_scale` | number; ≥ 0 | `1` | Multiplier on backend gravity. |
| `type` | `"dynamic"`, `"kinematic"`, `"static"` | `"dynamic"` | Native body motion type. |
| `linear_damping` | number; ≥ 0 | `0` | Linear velocity damping. |
| `angular_damping` | number; ≥ 0 | `0` | Angular velocity damping. |
| `allow_fast_rotation` | boolean | `false` | Allow fast native-body rotation. |

### BoxCollider

3D box collision geometry with positive size dimensions, scaled from the entity transform. With a `RigidBody3D`, the native body controls motion; without one, static geometry is the normal setup. The legacy character mover treats it as axis-aligned. An optional `physics_material` object overrides matching top-level material fields; omitted nested fields retain the top-level values.

[Guide / example](physics.md) · [Implementation](../rune/ecs/physics.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `size` | 3-item array of number | `[1, 1, 1]` | Full dimensions in local units. |
| `is_static` | boolean | `true` | Static-collider participation; native motion is owned by RigidBody3D when present. |
| `is_sensor` | boolean | `false` | Report overlaps without solid collision response. |
| `friction` | number; ≥ 0 | `0.6` | Nonnegative surface friction. |
| `restitution` | number; ≥ 0 | `0` | Nonnegative bounce coefficient. |
| `rolling_resistance` | number; ≥ 0 | `0` | Nonnegative rolling resistance. |
| `physics_material` | object | Omitted; top-level values | Optional per-field overrides for the top-level material values. |
| `physics_material.friction` | number; ≥ 0 | Inherit top-level `friction` | Nonnegative surface friction. |
| `physics_material.restitution` | number; ≥ 0 | Inherit top-level `restitution` | Nonnegative bounce coefficient. |
| `physics_material.rolling_resistance` | number; ≥ 0 | Inherit top-level `rolling_resistance` | Nonnegative rolling resistance. |

### SphereCollider

3D sphere collision geometry. Radius uses the largest absolute transform scale axis. Pair with a rigid body for native motion; `is_static` also controls participation in the legacy character mover. Optional nested physics-material values override matching top-level fields.

[Guide / example](physics.md) · [Implementation](../rune/ecs/physics.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `radius` | number; > 0 | `0.5` | Radius in world/local units as described above. |
| `is_static` | boolean | `true` | Static-collider participation; native motion is owned by RigidBody3D when present. |
| `is_sensor` | boolean | `false` | Report overlaps without solid collision response. |
| `friction` | number; ≥ 0 | `0.6` | Nonnegative surface friction. |
| `restitution` | number; ≥ 0 | `0` | Nonnegative bounce coefficient. |
| `rolling_resistance` | number; ≥ 0 | `0` | Nonnegative rolling resistance. |
| `physics_material` | object | Omitted; top-level values | Optional per-field overrides for the top-level material values. |
| `physics_material.friction` | number; ≥ 0 | Inherit top-level `friction` | Nonnegative surface friction. |
| `physics_material.restitution` | number; ≥ 0 | Inherit top-level `restitution` | Nonnegative bounce coefficient. |
| `physics_material.rolling_resistance` | number; ≥ 0 | Inherit top-level `rolling_resistance` | Nonnegative rolling resistance. |

### CharacterController

The original simple upright 3D collision controller. Transform position is the camera eye, not the feet. Gameplay explicitly calls `ecs.move_character`; it resolves against static box/sphere colliders. Eye height must not exceed total height. `grounded` and `vertical_velocity` are runtime-only. For fixed-step capsule movement, slopes, stairs, crouching, and platforms, use `CharacterController3D`.

[Guide / example](../README.md#basic-3d-collision) · [Implementation](../rune/ecs/physics.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `radius` | number; > 0 | `0.35` | Radius in world/local units as described above. |
| `height` | number; > 0 | `1.8` | Total upright collision-volume height. |
| `eye_height` | number; > 0 | `1.6` | Feet-to-eye distance; no greater than height. |
| `gravity` | number; > 0 | `24` | Downward acceleration in units/second squared. |
| `jump_speed` | number; > 0 | `8` | Upward launch speed. |

### CharacterController3D

Fixed-step native query capsule motor. Requires an unparented unit-scale `Transform` whose position is the feet. Do not add another rigid body/collider or the legacy controller to that entity. Camera and input are game-owned. Require `2 * radius <= crouch_height <= height` and `step_height < height`. Gravity frame, velocity, requests, and support state are runtime data exposed by the controller APIs.

[Guide / example](character-controller-3d.md) · [Implementation](../rune/ecs/character_controller_3d.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `radius` | number; > 0 | `0.35` | Radius in world/local units as described above. |
| `height` | number; > 0 | `1.8` | Total height, including capsule caps. |
| `crouch_height` | number; > 0 | `1` | Crouched total height. |
| `move_speed` | number; ≥ 0 | `5` | Maximum ground movement speed in units/second. |
| `sprint_multiplier` | number; ≥ 1 | `1.8` | Multiplier on normal movement speed. |
| `crouch_speed` | number; ≥ 0 | `2.5` | Crouched movement speed. |
| `acceleration` | number; > 0 | `35` | Ground acceleration in units/second squared. |
| `braking` | number; > 0 | `45` | Ground deceleration in units/second squared. |
| `air_acceleration` | number; ≥ 0 | `10` | Air steering acceleration in units/second squared. |
| `gravity` | number; > 0 | `24` | Downward acceleration in units/second squared. |
| `jump_speed` | number; ≥ 0 | `8` | Upward launch speed. |
| `jump_cut_multiplier` | number; ≥ 0; ≤ 1 | `0.5` | Remaining upward-speed fraction on early jump release. |
| `max_fall_speed` | number; > 0 | `45` | Terminal downward speed. |
| `max_slope_angle` | number; ≥ 0; < 89 | `45` | Walkable slope limit in degrees. |
| `ground_snap_distance` | number; ≥ 0 | `0.2` | Maximum downward ground snap. |
| `step_height` | number; ≥ 0 | `0.3` | Maximum stair/curb height; zero disables. |
| `coyote_time` | number; ≥ 0; ≤ 1 | `0.1` | Jump grace period after leaving support, in seconds. |
| `jump_buffer_time` | number; ≥ 0; ≤ 1 | `0.1` | Queued jump lifetime in seconds. |
| `push_force` | number; ≥ 0 | `50` | Maximum horizontal force on dynamic obstacles; zero disables. |

## Navigation

### NavGrid2D

Stores raster navigation configuration. It does not build or update a navigation grid automatically. Game code creates a `navigation.Grid`, rasterizes its own obstacles (including agent clearance), and calls `navigation.find_path`. Grid origin, dimensions, blocked cells, and paths are runtime data. See the 2D navigation walkthrough below.

[Guide / example](#2d-navigation-workflow) · [Implementation](../rune/ecs/navigation.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `cell_size` | number; > 0 | `24` | Raster cell size in world units. |
| `algorithm` | `"a_star"`, `"theta_star"` | `"a_star"` | A* or any-angle Theta*; game code passes the selected algorithm to navigation.find_path. |

### NavAgent2D

Stores reusable path-following settings; it has no destination, speed, or automatic movement system. Game code applies radius when building clearance, repath interval when scheduling queries, and arrival distance when advancing waypoints. The Tanks example implements this flow. See the 2D navigation walkthrough below.

[Guide / example](#2d-navigation-workflow) · [Implementation](../rune/ecs/navigation.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `radius` | number; > 0 | `8` | Agent clearance radius used by game-owned obstacle rasterization. |
| `repath_interval` | number; > 0 | `0.25` | Seconds between path queries scheduled by game code. |
| `arrival_distance` | number; ≥ 0 | `4` | World-space waypoint arrival tolerance used by game code. |

### NavMesh3D

References a baked triangle navmesh asset. Vertices are in world space; a transform or parent does not move the surface. No transform is required. Disabling the entity makes its surface unavailable. Asset refresh is handled by the scene loop; geometry edits require rebaking.

[Guide / example](navigation-3d.md) · [Implementation](../rune/ecs/navigation_3d.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `asset` | string; nonempty | Required | Project-relative .navmesh.json asset; vertices are world-space agent-center positions. |

### NavAgent3D

Fixed-step navigation agent with a reference to a `NavMesh3D` entity. Requires an unparented unit-scale transform at the feet. Default mode moves the transform along the navmesh without physical collision or gravity. Set `drive_controller: true` and add `CharacterController3D` for physical movement; match standing dimensions and slope limits. Targets, paths, and status use the navigation APIs, not JSON.

[Guide / example](navigation-3d.md) · [Implementation](../rune/ecs/navigation_3d.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `mesh` | object | Required | Entity reference object: {"id":"navigation"}. |
| `mesh.id` | string; nonempty | Required | Stable scene ID of the NavMesh3D entity. |
| `speed` | number; ≥ 0 | `3` | Movement speed in world units/second. |
| `radius` | number; ≥ 0 | `0.3` | Radius in world/local units as described above. |
| `height` | number; > 0 | `1.8` | Standing agent clearance height. |
| `max_slope` | number; ≥ 0; < 89 | `45` | Walkable navigation slope in degrees. |
| `max_projection` | number; ≥ 0 | `1` | Maximum distance for projecting onto the navmesh. |
| `arrival_distance` | number; > 0 | `0.12` | Waypoint/goal arrival tolerance in world units. |
| `repath_interval` | number; > 0 | `0.5` | Seconds between path recomputations. |
| `drive_controller` | boolean | `false` | Drive a CharacterController3D instead of moving Transform directly. |

## Interactions and triggers

### Interactable3D

An interaction target on an entity with `Transform`. Offset is unscaled and world-axis aligned. Zero hold time is a press action; positive time requires a hold. Prompt is data for game-owned UI. Odin handles the resulting door, pickup, dialogue, or other behavior.

[Guide / example](interactions-3d.md) · [Implementation](../rune/ecs/interaction_3d.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `prompt` | string; nonempty | `"Use"` | Game UI prompt text. |
| `offset` | 3-item array of number | `[0, 0, 0]` | Unscaled world-axis offset from the entity position. |
| `hold_seconds` | number; ≥ 0 | `0` | Required hold duration; zero is a press action. |
| `enabled` | boolean | `true` | Enable this feature/profile. |

### Interactor3D

Reach, facing cone, and visibility configuration on the actor, which also needs `Transform`. Gameplay supplies the reach origin and forward vector to the interaction APIs. Layer values are numeric bit masks from project layers; defaults accept every bit. Target finding does not bind input or draw prompts.

[Guide / example](interactions-3d.md) · [Implementation](../rune/ecs/interaction_3d.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `range` | number; > 0 | `3` | Maximum interaction reach in world units. |
| `half_angle` | number; ≥ 0; ≤ 180 | `65` | Facing cone half-angle in degrees. |
| `target_layers` | integer; ≥ 0; ≤ 18446744073709551615 | All 64 bits set (omit) | Accepted target layer bit mask. |
| `obstruction_layers` | integer; ≥ 0; ≤ 18446744073709551615 | All 64 bits set (omit) | Visibility blocker layer bit mask. |
| `require_line_of_sight` | boolean | `true` | Check occlusion before selecting a target. |

### Trigger3D

A query-only box/sphere zone on an entity with `Transform`; it never blocks movement and needs no rigid body/collider of its own. Boxes remain world-axis aligned, dimensions follow absolute hierarchy scale, and offset is unscaled world space. The fixed-step loop buffers enter/stay/exit events; consume them in `post_physics` to observe every step.

[Guide / example](triggers-3d.md) · [Implementation](../rune/ecs/triggers_3d.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `shape` | `"box"`, `"sphere"`, `0`, `1` | `"box"` | box (0) or sphere (1); numeric forms support typed serialization. |
| `size` | 3-item array of number; > 0 | `[2, 2, 2]` | Full dimensions in local units. |
| `radius` | number; > 0 | `1` | Radius in world/local units as described above. |
| `offset` | 3-item array of number | `[0, 0, 0]` | Unscaled world-axis offset from the zone position. |
| `layers` | integer; ≥ 0; ≤ 18446744073709551615 | All 64 bits set (omit) | Accepted target layer bits; all bits by default. |
| `enabled` | boolean | `true` | Enable this feature/profile. |
| `include_sensors` | boolean | `false` | Include sensor colliders in trigger overlaps. |

## Audio

### AudioListener

Selects the scene audio reference point, normally on a camera entity with a transform. Sharing a camera is a convention, not a requirement. Keep one active listener. Entity activation also affects selection.

[Guide / example](../README.md#audio-component-data) · [Implementation](../rune/ecs/audio.odin)

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `active` | boolean | `true` | Select this camera/listener. |

### AudioPlayer

Named audio instances on an entity. Supply a nonempty sound path or nonempty clips list; clips overrides sound and chooses randomly per play. Music formats stream; short effects use buffered voices. Playback is game-owned unless `play_on_start` is true. Spatial audio uses emitter/listener positions. `max_distance >= min_distance`. Disabled entities suspend playback; mix bus settings live at engine/project level.

[Guide / example](audio-mixer.md) · [Implementation](../rune/ecs/audio.odin)

Example `components` map:

```json
{
  "AudioPlayer": {
    "jump": {"sound": "assets/jump.wav", "bus": "sfx"},
    "music": {"sound": "assets/theme.ogg", "bus": "music", "looping": true}
  }
}
```

The following fields belong to each named instance. Use
`ecs.get_audio_player(world, entity, "jump")` and
`ecs.set_audio_player(world, entity, "jump", value)` for typed access.

| Field | Type / constraints | JSON default | Meaning |
| --- | --- | --- | --- |
| `sound` | string | One source required | Project-relative sound/music path. |
| `clips` | array of string; nonempty | One source required | Randomly select one clip per play; overrides sound when non-empty. |
| `bus` | `"master"`, `"music"`, `"sfx"`, `"ui"` | `"sfx"` | Mixer bus. |
| `volume` | number; ≥ 0 | `1` | Base volume multiplier. |
| `pitch` | number; > 0 | `1` | Base pitch multiplier. |
| `random_volume` | number; ≥ 0 | `0` | Uniform per-play variation around volume. |
| `random_pitch` | number; ≥ 0 | `0` | Uniform per-play variation around pitch. |
| `max_voices` | integer; ≥ 1 | `4` | Maximum simultaneous buffered voices for this instance. |
| `looping` | boolean | `false` | Loop playback. |
| `play_on_start` | boolean | `false` | Start when the scene audio is initialized. |
| `spatial` | boolean | `false` | Attenuate using listener/emitter positions. |
| `min_distance` | number; ≥ 0 | `1` | Distance before attenuation begins. |
| `max_distance` | number; ≥ 0 | `20` | Outer attenuation distance; at least min_distance. |

## 2D navigation workflow

`NavGrid2D` and `NavAgent2D` are settings read by game code. They do not select a
destination, infer obstacles from a scene, or move entities automatically.

```json
{
  "name": "2D navigation settings",
  "entities": [
    {"id": "navigation", "components": {"NavGrid2D": {"cell_size": 24, "algorithm": "theta_star"}}},
    {"id": "guard", "components": {"Transform": {}, "NavAgent2D": {"radius": 8, "repath_interval": 0.25, "arrival_distance": 4}}}
  ]
}
```

1. Read the settings with `ecs.get(world, entity, ecs.NavGrid2D)` and
   `ecs.get(world, entity, ecs.NavAgent2D)`.
2. Import `rune:navigation`; create a grid with `navigation.init_grid(width,
   height, config.cell_size, origin)`. Game code owns its dimensions and origin.
3. Mark blocked cells with `navigation.set_blocked` or `block_world_rect`.
   Account for `agent.radius` when rasterizing obstacles; the path query itself
   receives the already prepared grid, not the agent component.
4. Convert positions with `world_to_cell`, map the component algorithm to
   `navigation.Algorithm.A_Star` or `.Theta_Star`, and call `find_path`.
5. Move toward `cell_center` waypoints using the game's movement/collision code.
   Use `arrival_distance` to advance waypoints and `repath_interval` to schedule
   queries. Rebuild blocked cells when the game's obstacles change.
6. Free an owned returned path with `delete(path)` and the grid with
   `navigation.destroy_grid(&grid)` when replacing them or shutting down.

The [Tanks implementation](../examples/tanks/tanks_game.odin) demonstrates grid
creation, radius-aware blocking, timed replanning, and waypoint following. The
[navigation implementation](../rune/navigation/grid.odin) defines the lower-level
grid API. [3D navigation](navigation-3d.md) has its own engine-driven agents and
baked mesh workflow.

## Keeping this reference current

When adding or changing a built-in, update its entry here, its schema, and its
focused guide/example together. Compare the names against
[`registry.odin`](../rune/ecs/registry.odin), resolve component `$ref` entries in
[`components.schema.json`](../schemas/components.schema.json), and include nested
fields from [Skybox](../schemas/skybox.schema.json) and
[PostProcessing](../schemas/post-processing.schema.json). Verify omitted-field
defaults through the JSON decoder/default helper, not zero-initialized structs.
Check runtime-only fields separately from authorable JSON and retain the
distinction between automatic engine systems and game-owned calls.
