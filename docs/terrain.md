# Heightmap terrain

Rune terrain is a code-first, file-authored landscape: a heightmap supplies one
height at each X/Z coordinate, a descriptor supplies its dimensions and material,
and a scene entity places it in the world. The first version supports fixed
resolution mesh chunks, lighting/shadows, static collision, and live asset reload.

```json
"Transform": {"position": [-128, 0, -128]},
"Terrain": {"asset": "assets/hills.terrain.json"}
```

The entity requires `Transform`. `Terrain.collision` and `Terrain.shadows` default
to `true`; `Terrain.friction` defaults to `0.8`. Terrain owns a static body and
cannot share its entity with another 3D collider, rigid body, or character
controller. Place those on separate entities.

## Descriptor and heightmap

```json
{
  "heightmap": "assets/hills.png",
  "resolution": [257, 257],
  "size": [256, 256],
  "height_scale": 48,
  "height_offset": -6,
  "chunk_cells": 64,
  "uv_scale": [32, 32],
  "material": "assets/ground.material.json"
}
```

All referenced paths are relative to the **project root**, including paths inside
the descriptor. Absolute paths are also accepted. The schema is
`schemas/terrain.schema.json`; `*.terrain.json` files get completion in VS Code.

- `resolution` counts samples, including the final row and column. Each axis
  supports 2–513 samples. Rectangular maps and partial chunks are supported.
- `size` is the total local X/Z extent, default `[256,256]`. The first sample is
  at `(0,height,0)` and the last at `(size.x,height,size.z)`.
- `heightmap` accepts grayscale PNG without alpha (8-bit or 16-bit), or `.r16`
  containing unsigned little-endian 16-bit samples. Use 16-bit for smooth slopes.
  PNG dimensions must match `resolution`; raw files must contain exactly
  `width * height * 2` bytes. PNG decoding preserves 16-bit precision.
- Columns run along +X; rows run along +Z. The top-left image pixel is the
  local origin. Height is `height_offset + normalized_sample * height_scale`.
- `height_scale` defaults to 32 and `height_offset` to 0. Zero height scale
  produces flat ground. Both descriptor and component fields are validated.
- `chunk_cells` accepts 8, 16, 32, 64, or 128, default 64. The example has
  sixteen 64×64-cell render chunks, totaling 131,072 triangles.
- `uv_scale` repeats the material across the entire terrain, default `[16,16]`.
  The material uses the existing PBR material format. Terrain sets its texture
  maps to repeat; a material shared with other meshes therefore repeats there too.
  An empty material path uses a green fallback.

## Material and texture blending

### Up to eight layers

Use a `layers` list for 1–8 materials per terrain, with color, normals,
roughness, metalness, occlusion and specular blended together. This matches
[Unity HDRP's eight-layer limit](https://docs.unity3d.com/6000.0/Documentation/Manual/class-TerrainLayer.html);
Unity's URP/Built-in multi-pass system can exceed eight. Rune renders the eight
layers in one surface pass. Paths are relative to the project root.

```json
"layers": [
  {"name":"Grass", "material":"assets/grass.material.json", "tile_size":[4,4], "height":[0,4,20,28], "slope":[-1,0,18,32]},
  {"name":"Sand", "material":"assets/sand.material.json", "height":[-100001,-100000,0,4]},
  {"name":"Rock", "material":"assets/rock.material.json", "tile_size":[6,6], "slope":[18,32,90,91]},
  {"name":"Snow", "material":"assets/snow.material.json", "height":[20,28,100000,100001]}
]
```

Each layer has:

- `material`: a material JSON, including procedural generation, or a color image.
- `tile_size`: X/Z terrain units per texture repeat, default `[4,4]`.
- `weight`: nonnegative contribution multiplier, default `1`, maximum `1000`.
- `height` and `slope`: four increasing values for fade-in start/end, then
  fade-out start/end. Equal endpoints give hard edges. Defaults cover the full
  supported terrain height/slope ranges. Heights and slopes are terrain-local.

Automatic weights multiply the height and slope bands by `weight`, then normalize
the result across active layers. Unrestricted layers with equal weights blend
equally. If every weight is zero, layer 0 covers the surface.

For authored placement, add `control_maps`: one RGBA image for layers 0–3,
and a second for layers 4–7. Supply one map per group of four layers:

```json
"control_maps": ["assets/weights_0.png", "assets/weights_1.png"]
```

Red, green, blue and alpha select consecutive layers. Weight maps replace the
automatic height/slope rules; the layer's `weight` multiplier still applies.
Channels are linear weights and are normalized, so they need not sum to 255.
Unused channels are ignored; all-zero areas select layer 0. Maps cover the whole
terrain from X/Z origin at the image's top-left to its opposite corner, use
bilinear sampling, and clamp at the edge. Preserve alpha when exporting: it is
a layer weight, not transparency. Author these images in an image tool or generate
them in code; Rune does not yet provide a terrain painting UI.

Each material retains its own filtering and independent procedural resolution
(8–1024). Use `"filter":"point", "mipmaps":false` for crisp texels; weight-map
transitions remain smooth. Layer maps are packed into two GPU atlases, each
holding four materials. Layers in a group are expanded with nearest sampling
to the group's largest map size; lower-resolution texels remain intact. Color,
normal and ORM maps are limited to 1024 pixels per side, and control maps to 2048.
Large sets cost more texture memory and sampling work; use only the layers needed.

Material and control-map edits hot reload without rebuilding terrain geometry.
Invalid reloads retain the last working assets. Missing first-time assets fall
back to the base terrain material and report diagnostics. Use a white base
material to preserve layer colors. Base lighting, emission, alpha and shadows
still control the entire terrain; layer transparency/emission are not blended.

Do not combine a nonempty `layers` list with an enabled legacy `blend` object.
Omitting both keeps the single base material. The Highland Walk example uses
all eight slots with automatic height/slope placement.

### Legacy three-layer blend

Add an optional `blend` object to the terrain descriptor to mix three materials
or color textures automatically. Paths are relative to the project root, as for the
heightmap. Existing descriptors without `blend` keep their single material.

```json
"blend": {
  "grass": "assets/grass.material.json",
  "dirt": "assets/dirt.material.json",
  "rock": "assets/rock.material.json",
  "dirt_height": [3, 9],
  "rock_slope": [20, 38],
  "noise_scale": 0.12,
  "noise_strength": 0.2
}
```

Supply all three paths to enable blending. Dirt covers low ground, fading to
grass between the two `dirt_height` values. Rock overrides that mix as the slope
increases between the two `rock_slope` angles (degrees, 0–90). Both ranges must
increase. These thresholds use local terrain coordinates, so moving or rotating
the entity keeps its painted appearance attached. Noise adds irregularity to
the transitions; `noise_strength: 0` disables it. The values above are defaults.

The renderer projects textures along three axes and blends those projections
using the surface normal, reducing stretching on steep faces. `uv_scale` controls
repeats across the full X/Z extent; the vertical repeat rate averages those two
rates. Each JSON layer uses its material's `filter` and `mipmaps` settings.
For a retro layer, use `"filter": "point", "mipmaps": false`; procedural
`resolution` remains independent and can be as low as 8. Scene FXAA can still
soften edges, so disable it for a fully crisp result. Image paths use mipmaps
and anisotropic filtering. All layers repeat across the terrain.

Blending multiplies the material's albedo; use a white `base_color` and no base
texture for the original layer colors. A `.json` path loads a material, including
procedural generation and file-map overrides. If any layer uses a material,
the renderer also blends layer normals, roughness, metalness, occlusion and
specular strength. These replace the corresponding base surface channels.
Base lighting, emission, alpha and shadows still control the whole terrain;
layer transparency and emission are not blended.

Images and materials can be mixed: an image contributes color, a flat normal,
and the base material's scalar roughness, metalness and specular. Three image
paths retain the original color-only blend with base normal and ORM maps.

Material-layer maps are cached in one atlas per layer. Maps within a layer are
resampled with nearest sampling to a shared square power-of-two size (8–1024);
larger file maps are reduced to 1024. Cell-aware wrapping and mip selection keep
color, normal and ORM data separate, including at a distance. Anisotropic
filtering uses up to the requested 4, 8 or 16 directional samples.

Material and texture edits hot reload without rebuilding terrain geometry.
Invalid replacements retain the previous loaded assets. An unavailable layer
falls back to the base material with an asset diagnostic. Descriptor edits reload
the blend settings with the terrain. Remove `blend` or set it to `{}` to disable it.

## Grass, trees, rocks and other details

Add a `details` list to scatter decorative objects directly from the terrain asset:

```json
"details": [
  {"name":"Grass", "kind":"grass", "count":60000, "seed":42, "height":[0,23], "slope":[0,24], "scale":[0.9,1.6], "draw_distance":55},
  {"name":"Pines", "kind":"tree", "count":420, "seed":71, "height":[2,23], "slope":[0,23], "draw_distance":280},
  {"name":"Rocks", "kind":"rock", "count":650, "seed":183, "scale":[0.35,1.35], "draw_distance":150},
  {"name":"Flowers", "kind":"model", "model":"assets/flower.glb", "material":"assets/flower.material.json", "count":500, "seed":12}
]
```

The built-in grass tufts, pine trees and rocks use original low-poly geometry
with vertex colors, so they require no downloaded assets. Custom static models
use `kind:"model"` and a project-relative `model` path. Author them with +Y up
and the pivot at ground level. The optional material JSON applies to every mesh
in a prototype and can use procedural maps. Without it, the renderer uses white
with mesh vertex colors; imported model material textures are not retained.

`count` is the number of candidate cells spread across the terrain, not a
guaranteed final object count. The seeded jitter pattern is repeatable; candidates
outside inclusive `height` or `slope` ranges are omitted. Height and slope use
terrain-local coordinates. Change seeds between detail types for independent
placement patterns. `scale` sets the min/max uniform scale, with random yaw and
subtle shade variation added automatically. Ground placement uses the exact
terrain triangles. Detail positions follow terrain transforms and regenerate
after successful heightmap or descriptor edits.

Defaults are 1,000 candidates, seed 0, scale `[0.8,1.2]`, unrestricted height,
and slope `[0,35]`. `align_to_normal` tilts objects onto the ground; it defaults
to true for rocks and false for other kinds. `shadows` defaults to false for
grass and true otherwise. Built-in tree height is approximately 5.2 units,
rock height 1.13 units, and grass blade height 0.35–0.6 units, before scaling.

Details use GPU instancing rather than individual scene entities. `draw_distance`
is measured from the camera in world units (default 60 for grass, 250 otherwise).
Grass shrinks smoothly through the last 20% of that distance; other details are
culled at the limit. Terrain supports at most 32 detail definitions, 100,000
candidates per definition, and 250,000 candidates total. Increase counts with
care: instance selection still scans their positions each frame, and dense
shadow-casting geometry has a rendering cost.

These details are decorative: they do not create colliders, navigation obstacles,
or individually interactable entities. Use regular scene/prefab entities for
trees or rocks that need those behaviors. Scatter placement currently uses
height/slope rules rather than painted density maps or terrain layer weights.

Invalid descriptor edits retain the working terrain and detail buffers. Model
and material assets use their existing hot-reload paths. Removing a terrain or
replacing the scene releases its detail instance buffers.

## Geometry and collision

Normals use neighboring samples across chunk boundaries. Collision uses the
same triangle diagonal as rendering, stored in one native Box3D triangle mesh
per terrain entity so collision edges remain connected across render chunks.
Collision is one-sided, facing upward. It works with `CharacterController3D`,
dynamic rigid bodies, physics queries, layer masks, and contact events. Query
hits identify the component as `Terrain`.

Terrain supports rotation, translation, and positive nonuniform scale. Parent
transforms follow Rune's existing renderer convention: positions and Euler
angles add and scales multiply. A missing Transform, zero/negative scale, or
disabled ancestor omits both rendering and collision. Avoid enormous scales;
the sample resolution cap is a practical first-version limit, not an open-world
performance guarantee.

## Code, reload, and lifetime

Terrain also feeds the [3D navigation baker](navigation-3d.md). It uses the same
heightmap triangles and world transform as collision, filters slopes/headroom,
and combines the landscape with static obstacles. Run from the repository root
with PowerShell 7 on Windows or Linux:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run tools/navmesh_baker -collection:rune=rune "-out:build/navmesh_baker$exe" -- examples/terrain_3d/terrain.navbake.json
```

Press **N** in Highland Walk to inspect the result.
Re-run the bake after terrain edits. The output navmesh hot reloads separately
from the terrain, and its cell size controls the approximation between samples.

```odin
settings := ecs.default_terrain()
settings.asset = "assets/hills.terrain.json"
ecs.add(world, registry, entity, settings)

settings.collision = false
ecs.set(world, entity, settings)

data, revision, ready := ecs.terrain_runtime(world, entity)
if ready {
    local_height, inside := terrain.sample_height(data, 12, 34)
}
```

Import `rune:terrain` for CPU data loading, grid positions/normals, and local
height sampling. `sample_height` interpolates the actual triangles, not a
bilinear surface. For world-space queries, use `ecs.physics_3d_raycast`.
Borrowed runtime data is read-only and valid until terrain synchronization or
World destruction. `terrain.clone` creates an independent owned copy, released
with `terrain.destroy`.

The scene-owning engine synchronizes terrain before start callbacks and before
simulation each frame. `hot_reload.terrains` defaults to true and observes the
project's normal polling interval. Both descriptor and heightmap edits reload
while the simulation is paused. Invalid files retain the last working surface
and collider; a missing first asset omits the terrain and reports a diagnostic.
Creating or repairing a watched file retries loading. Material edits follow
the existing material hot-reload setting.

Callback loops call `assets.refresh_terrains(manager)` at their polling interval
and `ecs.sync_terrains(world, manager)` before physics and drawing. GPU chunks
belong to the r3d bridge, collision meshes and runtime sample copies to the
World, and source data to the asset manager. Shut the bridge down while the
graphics context is still alive, as with other 3D examples.

This version rebuilds the whole terrain on successful height/descriptor edits.
Large edits can cause a frame stall. It does not yet provide distance LOD,
streaming, brush tools, layer painting, holes, or caves/overhangs.
Separate model entities can supply cave and cliff geometry later.

## Example and checks

```powershell
odin build examples/terrain_3d -collection:rune=rune -collection:r3d=third_party/r3d-odin -out:build/terrain_3d.exe
./build/terrain_3d.exe --console-dir=build/console/terrain
```

On Linux, use `-out:build/terrain_3d` and run that executable. PowerShell scripts
in the repository select the appropriate extension automatically.

`tools/terrain_validation` checks decoding, collision, character traversal,
activation, hierarchy edits, reload recovery, and ownership. Its GPU checks also
verify image/material layer colors, normal and ORM blending, point filtering,
atlas mip isolation, eight material slots/control channels, reload retention,
noise continuity and shader cleanup. It runs as part of
`pwsh -NoProfile -File tools/validate.ps1 -AllExamples`.

To run its GPU checks independently:

```powershell
odin build tools/terrain_validation -collection:rune=rune -collection:r3d=third_party/r3d-odin -out:build/terrain_validation.exe
./build/terrain_validation.exe --runtime
```

The optional `-Runtime` validation suite includes those checks. Linux GPU checks
need a desktop or Xvfb. PNG decoding uses Odin's `vendor:stb/image`; the toolchain
installer builds its native Linux archive when missing. For an existing Odin
installation without `vendor/stb/lib/stb_image.a`, run its
`vendor/stb/src/build_stb.sh unix` script. Windows libraries ship with Odin.
