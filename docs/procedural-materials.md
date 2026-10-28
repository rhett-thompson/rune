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
mipmap settings apply. The top-level `wrap` accepts `clamp`, `repeat`, or
`mirror_repeat`. Omitting it preserves file-map clamp and generated-map repeat
defaults; an explicit value applies to every material map.

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

Material reuse includes each path's texture/shader dependencies and the complete
material variant. Editing or previewing one material preserves another
material's maps and compiled shader when its own dependencies are unchanged.
An authored-path cache hit reads its revision from manager metadata; it does not
stat source files every draw. File polling and completed texture uploads update
the affected dependency generations. A direct `material_from_data` call still
distinguishes different filtering, wrapping, mipmap, and procedural settings
under the same path. The manager retains its aggregate material revision for
instance/batch invalidation.

Packed ORM generated from separate AO/roughness/metallic files remains owned by
the asset manager. Bridge materials retain leases while using those textures.
An affected source edit retires the old entry, whose GPU handle stays alive
until its final material lease is released. Replacing an editor variant releases
unused leased entries; unrelated material edits do not clear the whole ORM
cache. Advanced consumers can use `lease_material_orm_texture` and
`release_material_orm_texture` for the same lifetime guarantee. The ordinary
`material_orm_texture` API returns a borrowed handle that expires on an affected
refresh or explicit clear. Release bridge resources and leases before shutting
down the asset manager.

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

Live authoring tools can call `assets.set_material_preview(&manager, path, data)`
to override a material without writing a file. Start with `material_data` or
`authored_material_data`, clone it with `clone_material_data` when retaining it,
and keep edited values within the material's authoring limits. The setter owns
its own deep copy, preserves texture/shader/procedural fields, and updates the
asset revision used by existing R3D material and instance caches. Every object
using that path sees the same preview. `material_data` returns the preview;
`authored_material_data` bypasses it. Both getters return borrowed strings.

`clear_material_preview` restores one path, and `clear_material_previews`
restores all paths. Previews survive file hot reload until cleared and are
released at asset-manager shutdown. To save, the authoring tool writes its
material JSON, calls `refresh_materials`, then clears the preview so the latest
authored file stays visible. Rune does not serialize a preview or preserve
unknown JSON fields on the tool's behalf.

For imported models without component overrides, persist per-slot paths in the
optional `<model path>.materials.json` sidecar described under
[ModelRenderer](components.md#modelrenderer). These defaults are shared by every
instance of that model and refresh through `refresh_materials`.

Try [Procedural Materials 3D](../examples/procedural_material_3d/README.md) for
nine presets on keys **1–9**: stone, moss, hammered metal, grass, granite, wood,
sand, terracotta, and snow. All support independent resolution and sampling controls.

`tools/material_reload_validation --runtime` checks selective cache reuse,
own-source image/shader edits, failed-shader retention, sampler variants, and
generated ORM lease retirement using actual GPU textures. On 2026-10-28 these
checks and the serial asset tests passed with the pinned October Odin compiler,
MSVC, Windows AMD64, GLFW/Win32, OpenGL 3.3, and an NVIDIA GTX 1060. Linux runtime
behavior remains unverified by these runs.
