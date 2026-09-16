# Procedural materials

Add a `procedural` block to a material JSON file to generate seamless noise
textures for r3d primitives, terrain, and imported models with UVs. No source
images or custom shader are required. Rune generates color, tangent-space
normals, and roughness from the same layered noise field.

```json
{
  "lighting": true,
  "roughness": 0.9,
  "procedural": {
    "seed": 42,
    "scale": 10,
    "octaves": 4,
    "persistence": 0.5,
    "contrast": 1.3,
    "color_a": [58, 65, 74, 255],
    "color_b": [180, 185, 190, 255],
    "bump_strength": 0.01,
    "roughness_variation": 0.3
  }
}
```

Reference this file through the usual `material` field on `MeshRenderer`,
`SphereRenderer`, or `ModelRenderer`, or the `material` field of a terrain asset.
Models also support individual material-slot overrides. `lighting: true` enables PBR lighting;
an unlit material still displays the generated color texture.

## Controls

| Field | Default | Effect |
| --- | --- | --- |
| `enabled` | `true` | Disable generation while keeping the settings. An absent block disables generation. |
| `pattern` | `"noise"` | Layered noise, or `"wood"` for grain bands warped by seamless noise. |
| `resolution` | `256` | Square map size: 8, 16, 32, 64, 128, 256, 512, or 1024 pixels. |
| `seed` | `0` | Repeatable pattern, integer 0–65535. |
| `scale` | `8` | Noise cells per UV tile, integer 1–64. Larger values make finer features. |
| `octaves` | `4` | Detail layers, integer 1–6. |
| `persistence` | `0.5` | Each layer's contribution relative to the previous one, 0–1. |
| `contrast` | `1` | Pattern contrast, 0.1–8. |
| `color_a` | `[65,70,76,255]` | Color at noise value zero. |
| `color_b` | `[190,195,200,255]` | Color at noise value one. |
| `bump_strength` | `0.15` | Height-to-normal strength, 0–2; zero disables generated normals. Start around 0.01 for subtle stone. |
| `roughness_variation` | `0.3` | Variation, 0–1; zero disables the generated roughness map. |

`base_color` multiplies the generated color, and `normal_scale` multiplies the
normal-map strength. Roughness varies from
`roughness * (1 - roughness_variation)` to `roughness`, according to the noise.
The generated ORM map has white AO and metallic channels, preserving the
material's scalar AO and metallic controls. The usual texture filter and
mipmap settings apply.

### Retro sampling

For sharp texels without smoothing, add these fields at the material's top level:

```json
"filter": "point",
"mipmaps": false
```

This uses nearest-neighbor sampling for the color, normal, and roughness maps.
Use `procedural.resolution` of 8, 16, 32, or 64 for chunkier pixels. A high-resolution
noise map can still look smooth because neighboring texels have similar colors.
Set the scene's `PostProcessing.anti_aliasing` to `"disabled"` to prevent FXAA
from softening the pixel edges after rendering.

The demo's **Q / E** keys decrease/increase map resolution through 8, 16, 32, 64, 128,
256, 512, and 1024 pixels in either sampling mode. **F** toggles nearest-neighbor
sampling, no mipmaps, and no post-process anti-aliasing. Toggling it off restores
the previous sampling settings and preserves the currently chosen resolution.
Save the material and scene JSON settings above to keep the look.

Explicit `albedo`/`texture` and `normal` maps override their respective generated
maps. Any packed ORM or individual AO/roughness/metallic texture selects the
existing file-based ORM path instead of generated ORM. A broken explicit map
keeps the existing missing-asset diagnostic and fallback behavior.

## Reload and mapping

With material hot reload enabled, save the JSON to regenerate the surface.
Rune caches GPU maps per material path; matching materials reuse their maps
each frame. Replacements release the previous maps, and malformed JSON keeps
the last working material. Higher resolutions cost more generation time and
memory, so prefer 256 for interactive tweaking.

Noise repeats across UV boundaries, including its normal map. It uses the
mesh's UVs: UV stretching, cube face orientation, and sphere poles still affect
the result. This is a baked UV texture, with no geometric displacement or
world-space projection. Detail layers finer than two pixels are omitted after
the base octave to reduce aliasing; use enough resolution for your scale.

For Odin code, `assets.default_procedural_material()` creates settings and
`Material_Data.procedural` holds them. `assets.generate_procedural_material_images`
works without a window; release its three images with
`assets.destroy_procedural_material_images`. When calling
`r3d_bridge.material_from_data` directly, supply a stable nonempty material path
as its cache key so the bridge owns and releases the generated GPU maps.

Try [Procedural Materials 3D](../examples/procedural_material_3d/README.md) for
nine presets on keys **1–9**: stone, moss, hammered metal, grass, granite, wood,
sand, terracotta, and snow. All support independent resolution and sampling controls.
