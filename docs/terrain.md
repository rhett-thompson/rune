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

## Texture blending

Add an optional `blend` object to the terrain descriptor to mix three color
textures automatically. Paths are relative to the project root, as for the
heightmap. Existing descriptors without `blend` keep their single material.

```json
"blend": {
  "grass": "assets/grass.png",
  "dirt": "assets/dirt.png",
  "rock": "assets/rock.png",
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
rates. Textures use mipmaps, anisotropic filtering, and repeat wrapping. These
sampling settings also affect other users of the same cached textures.

Blending multiplies the material's albedo; use a white `base_color` and no base
texture for the original layer colors. Roughness, metallic, lighting and shadows
continue to come from the material. This blends color textures only, not separate
normal or roughness maps. An unavailable layer falls back to the base material
with an asset diagnostic. Texture edits use normal texture hot reload; invalid
replacements retain the last working texture. Descriptor edits reload the blend
settings with the terrain. Remove `blend` or set it to `{}` to disable it.

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
and combines the landscape with static obstacles. Run
`odin run tools/navmesh_baker -collection:rune=rune -- examples/terrain_3d/terrain.navbake.json`
from the repository root; press **N** in Highland Walk to inspect the result.
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
streaming, brush tools, layer painting, foliage, holes, or caves/overhangs.
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
verify blend layer colors, transitions, noise continuity and shader cleanup. It runs as part of
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
