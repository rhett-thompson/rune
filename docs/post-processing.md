# Post processing

Rune's optional r3d bridge renders a `PostProcessing` component from scene JSON,
prefabs, or Odin. The core ECS and project validator do not depend on r3d.
The profile controls 3D rendering; sprites, debug overlays, and HUD drawn after
`r3d_bridge.draw_scene_ex` are outside its effects.

## Scene authoring

Add a profile to a dedicated entity; no Transform is required:

```json
{
  "id": "post",
  "components": {
    "PostProcessing": {
      "anti_aliasing": "fxaa",
      "bloom": { "mode": "additive", "intensity": 0.12, "threshold": 1 },
      "film_grain": { "enabled": true, "intensity": 0.02 },
      "tonemap": { "mode": "aces", "exposure": 1 },
      "ssao": { "enabled": true, "radius": 1.5 },
      "color": { "saturation": 1.1 }
    }
  }
}
```

Every field is optional. Missing fields use Rune defaults, even within a
partially specified effect. An empty profile uses FXAA, linear tone mapping,
exposure/white/brightness/contrast/saturation of 1, and disables other effects.
All fields and defaults appear in
[`post-processing.schema.json`](../schemas/post-processing.schema.json).
Scene saves hot reload through the normal scene loader; prefab overrides and
runtime console inspection use the same component format.

## Bloom and film grain

Bloom spreads HDR highlights before tone mapping. Emissive materials feed it;
`threshold` selects bright pixels, `soft_threshold` softens the cutoff, and
`filter_radius` controls the blur width. Raise `intensity` for a stronger glow.

`film_grain` adds fine monochrome noise after tone mapping and anti-aliasing:

```json
"film_grain": { "enabled": true, "intensity": 0.02, "size": 1, "speed": 24 }
```

It is disabled by default. Intensity is a normalized strength from 0 to 1;
0.01–0.03 is subtle. Size is 1–8 rendered pixels. Speed is 0–60 pattern changes
per second; zero freezes the pattern. Animation uses render time, including when
simulation is paused. Zero intensity skips the pass. Symmetric triangular noise
preserves neutral colors and reduces strength near black/white to retain contrast.

The bridge owns the `FINAL` shader stage while grain is active, then clears it
after the draw. Its cached shader is released at shutdown. The HUD and debug
overlays drawn afterward are unaffected. Custom chains can use `POST` or `OUTPUT`;
`FINAL` remains available when film grain is inactive.

## Light shafts

`light_shafts` adds screen-space radial scattering around a finite light source.
Add it to the existing profile:

```json
"light_shafts": {
  "enabled": true,
  "source": "emitter",
  "color": [255,240,202,255],
  "intensity": 0.5,
  "radius": 0.7,
  "source_radius": 1,
  "samples": 32
}
```

Source is a stable entity ID with a Transform; it may be created at runtime.
The renderer resolves it each frame, including the bridge's additive parent
positions, so reload and replacement do not retain stale handles. Missing or
disabled sources contribute nothing. Radius is the effect extent in screen
heights; source_radius is a world radius enclosing the luminous mesh. A radius
that is too small lets the emitter occlude itself; a radius that is too large
allows nearby surfaces to be treated as part of the emitter.

The effect radially blurs a sky/emitter mask from opaque scene depth toward
the projected source. Near-pixel samples carry more weight, giving silhouettes
long radial shadow wedges. Architecture beyond the source also masks the sky;
the emitter's own depth and footprint remain bright. Scattering crosses
foreground surfaces to represent light in the air between them and the camera.
A wall filling the viewport contributes no shafts. A partially hidden core
can still produce beams through nearby openings. Fixed per-pixel sample jitter
reduces repeated silhouette bands without animated noise.
It turns off behind the camera and fades at the viewport edge. The SCENE shader
runs before height fog and built-in bloom/tone mapping; HUD is unaffected.
Samples from 8 to 64 trade smoothness for GPU cost. This approximates scattering
in screen space; transparent clouds do not write occlusion depth and cannot
cast shafts. It does not replace volumetric scattering or shadow maps.

`build/light_shafts_validation --runtime` (add `.exe` on Windows) checks real
GPU rendering, radial shadow contrast, foreground scattering, occluders beyond
the source, full-view walls, camera direction, off-screen sources, and toggles.
Headless validation checks defaults, strict ranges,
serialization, and ownership of the source ID.

## Fog

Fog is part of `PostProcessing`; add it to the scene's existing profile so the
other effects stay together:

```json
"fog": {
  "mode": "linear",
  "color": [38, 49, 67, 255],
  "start": 12,
  "end": 45,
  "sky_affect": 0
}
```

This keeps nearby objects clear and fades distant geometry toward the
third-person example's background color. Distances are measured from the camera
in world units. `linear` uses `start` and `end`; `exp` and `exp2` use `density`
(higher values produce thicker fog). `sky_affect` controls sky influence from
0 to 1. Use `mode: "disabled"` to turn fog off without disabling other effects.

This is distance fog applied to the rendered view. It does not create bounded
fog banks or volumetric light scattering. Scene edits hot reload; for a running
game, the console can also set `PostProcessing.fog.mode`, `.start`, `.end`,
`.density`, and `.color` on the profile entity.

### Height fog

`height_fog` adds an independent layer whose density decreases exponentially
with world Y. Use it to conceal lower terrain or structures in a deep haze:

```json
"height_fog": {
  "enabled": true,
  "color": [86, 102, 122, 255],
  "base_height": -60,
  "density": 0.008,
  "falloff": 0.055,
  "sky_distance": 1000
}
```

`density` is extinction per world unit at `base_height`; `falloff` is inverse
world units. Density follows `density * exp(-falloff * (y - base_height))`.
Increasing falloff confines fog more sharply below the base. Zero falloff gives
uniform density, and zero density has no effect. The layer is disabled by default.

The bridge integrates density along each camera-to-surface ray using scene
depth. Empty sky integrates over `sky_distance` world units so the lower
background blends with submerged geometry without an abrupt horizon band or
depending on the camera's far clip. Choose a sky distance beyond the structures
you want to conceal. The upper sky and nearby surfaces remain visible according
to the same density function. RGBA colors use the same sRGB convention as
distance fog; alpha is ignored. Transparent geometry without depth writes uses
the depth behind it. This layer provides extinction and color, not volumetric
light scattering or bounded fog banks.

For a second layer that thickens upward, add `upper_height_fog` to the same
profile. It has the same fields and defaults as `height_fog`, is disabled by
default, and can operate independently or alongside the lower layer:

```json
"upper_height_fog": {
  "enabled": true,
  "color": [160,188,215,255],
  "base_height": 210,
  "density": 0.012,
  "falloff": 0.03,
  "sky_distance": 1000
}
```

Upper density follows `density * exp(falloff * (y - base_height))`.
Keep `falloff` nonnegative; zero gives uniform fog for either layer. Base height
is the altitude where density equals the authored value, not a hard cutoff.
Raise it to expose more of tall structures; lower it to hide more. Each layer
uses its own sky distance. Both integrate analytic optical depth in log space,
avoiding overflow in dense upper/lower regions, and compose in one screen pass
(lower first, upper second). Zero-density and disabled layers contribute nothing.
If both are disabled or zero-density, the bridge adds no height-fog shader to
the chain. Existing profiles keep their original lower-fog behavior.

The moon disk and both height-fog layers share the bridge's `SCENE` stage, with the moon
drawn first. The bridge clears this chain after each render and releases its
cached shader at shutdown. Custom screen effects should use the other stages.

## Profile selection and lifetime

1. An enabled profile on the active Camera3D entity wins.
2. Otherwise, enabled profiles on entities without Camera3D are scene-wide
   candidates. The lowest entity handle wins if several exist. Prefer one
   global profile; handles reflect creation order.
3. Entity activation, including disabled ancestors, is respected.
   `PostProcessing.enabled = false` excludes just that profile. A disabled
   camera profile falls back to the scene-wide profile.

Each selected profile completely specifies the effects; camera profiles do
not merge with global profiles. Selection is evaluated on every draw, so camera
switches and runtime edits take effect on the next rendered frame, even paused.
There are no spatial volumes or automatic blending.

The bridge saves the existing r3d environment effects and anti-aliasing mode
when the first profile becomes active. When no profile remains (including after
removal, entity destruction, or scene reload), it restores those settings.
Background and ambient lighting remain under their existing Rune controls.
Games that never activate a profile retain direct `r3d.GetEnvironment()` control.
While a profile is active, set its component fields instead of editing the same
r3d settings directly.

r3d still has global rendering state. These are settings selected for Rune's
active view, not isolated renderer instances. Auto exposure uses r3d's single
temporal history; use it on one continuous scene render path.

## Effects and validation

| Group | Controls |
| --- | --- |
| `anti_aliasing` | `disabled`, `fxaa`, `smaa` |
| `bloom` | `disabled`, `mix`, `additive`, `screen`; intensity, threshold, soft threshold, levels, filter radius |
| `tonemap` | `linear`, `reinhard`, `filmic`, `aces`, `agx`; exposure multiplier and white point |
| `film_grain` | Enable, intensity 0–1, cell size 1–8 rendered pixels, animation speed 0–60 patterns/second |
| `color` | Brightness, contrast, saturation |
| `ssao` | Occlusion enable, sample count, intensity, power, radius, maximum screen radius, bias |
| `ssil` | Indirect light and occlusion strengths, sampling, radius, bias |
| `ssgi` | Global illumination enable, slices, edge fade, distance falloff, normal rejection, intensity, denoising |
| `ssr` | Reflections enable, ray/binary steps, step size, thickness, distance, edge fade |
| `fog` | `disabled`, `linear`, `exp2`, `exp`; RGBA color, start/end, density, sky influence |
| `height_fog` | Enable, RGBA color, world base height, density at base, exponential falloff, sky integration distance |
| `upper_height_fog` | Same controls as `height_fog`, with density increasing above the base height; disabled by default |
| `dof` | Enable, focus distance/scale, near scale, maximum blur |
| `auto_exposure` | Enable, minimum/maximum EV, EV compensation, bright/dark adaptation times |

JSON names use snake_case and lowercase mode strings. Unknown properties, null,
wrong scalar types, nonfinite values, and out-of-range values fail validation.
Counts and RGBA channels must be integers. Typed `ecs.add` and `ecs.set` enforce
the same value constraints; invalid writes leave the existing component intact.
Fog end must exceed start; maximum EV must be at least minimum EV.

Work limits are explicit: SSAO/SSIL samples 1–64, SSGI slices 1–32 and denoise
steps 0–8, SSR ray steps 1–256 and binary steps 0–32, and DoF blur 0–64.
Normalized fields are 0–1; radius, step size, focus scale, white point, and
adaptation times must be positive. Refer to the schema for individual bounds.

## Odin and console

```odin
profile := ecs.default_post_processing()
profile.bloom.mode = .additive
profile.tonemap.mode = .aces
ecs.add(world, registry, entity, profile)

value, found := ecs.get(world, entity, ecs.PostProcessing)
if found {
    value.tonemap.exposure = 1.5
    ecs.set(world, entity, value)
}
```

Named helpers `get_post_processing` and `set_post_processing` are also available.
Changes flow through normal component notifications and scene serialization.
`active_post_processing_entity(world, camera)` returns the selected profile's
owner and a success flag, using the same camera override/global fallback rules
as `active_post_processing`. Tools can use it to edit the rendered profile.

```powershell
.\tools\console.bat --directory build/console/post --command 'inspect post PostProcessing' --json
.\tools\console.bat --directory build/console/post --command 'set post PostProcessing.bloom.intensity 0.2' --json
.\tools\console.bat --directory build/console/post --command 'set post PostProcessing.enabled false' --json
```

Console changes are runtime-only. Edit scene JSON to persist them.
Custom fullscreen shader chains remain available through r3d's
`LoadScreenShader` and stage-chain APIs. The bridge reserves `SCENE` while
drawing its moon and height fog, and `FINAL` while film grain is active; this
component does not load custom shader assets.

## Example and checks

From the repository root:

```powershell
odin build examples/post_processing_3d -collection:rune=rune -linker:msvc -collection:r3d=third_party/r3d-odin -out:build/post_processing_3d.exe
./build/post_processing_3d.exe --console-dir=build/console/post
```

On Linux, use `-out:build/post_processing_3d` and `./build/post_processing_3d`.
The example is also listed as **Post Processing 3D** in the launcher.

Space compares the profile with the baseline; B toggles bloom, O occlusion,
D depth of field, T cycles tone mapping, and Up/Down change exposure.
Left-drag orbits the camera. Edit
`examples/post_processing_3d/scenes/main.scene.json` while running to reload.
Glowing material JSON files demonstrate emission feeding bloom.

`.\tools\validate.bat --all-examples` includes headless
post-processing validation. Adding `--runtime` exercises r3d effect rendering,
baseline restoration, and grain's monochrome pixel variation, animation, frozen
pattern, pixel size after AA, and cleanup on toggles/removal. Linux runtime
validation requires a desktop or Xvfb.
