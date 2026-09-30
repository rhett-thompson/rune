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

The moon disk and height fog share the bridge's `SCENE` stage, with the moon
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
| `color` | Brightness, contrast, saturation |
| `ssao` | Occlusion enable, sample count, intensity, power, radius, maximum screen radius, bias |
| `ssil` | Indirect light and occlusion strengths, sampling, radius, bias |
| `ssgi` | Global illumination enable, slices, edge fade, distance falloff, normal rejection, intensity, denoising |
| `ssr` | Reflections enable, ray/binary steps, step size, thickness, distance, edge fade |
| `fog` | `disabled`, `linear`, `exp2`, `exp`; RGBA color, start/end, density, sky influence |
| `height_fog` | Enable, RGBA color, world base height, density at base, exponential falloff, sky integration distance |
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

```powershell
./tools/console.ps1 -Directory build/console/post -Command 'inspect post PostProcessing' -Json
./tools/console.ps1 -Directory build/console/post -Command 'set post PostProcessing.bloom.intensity 0.2' -Json
./tools/console.ps1 -Directory build/console/post -Command 'set post PostProcessing.enabled false' -Json
```

Console changes are runtime-only. Edit scene JSON to persist them.
Custom fullscreen shader chains remain available through r3d's
`LoadScreenShader` and stage-chain APIs. The bridge reserves `SCENE` while
drawing its moon and height fog; this component does not load custom shader assets.

## Example and checks

From the repository root:

```powershell
odin build examples/post_processing_3d -collection:rune=rune -collection:r3d=third_party/r3d-odin -out:build/post_processing_3d.exe
./build/post_processing_3d.exe --console-dir=build/console/post
```

On Linux, use `-out:build/post_processing_3d` and `./build/post_processing_3d`.
The example is also listed as **Post Processing 3D** in the launcher.

Space compares the profile with the baseline; B toggles bloom, O occlusion,
D depth of field, T cycles tone mapping, and Up/Down change exposure.
Left-drag orbits the camera. Edit
`examples/post_processing_3d/scenes/main.scene.json` while running to reload.
Glowing material JSON files demonstrate emission feeding bloom.

`pwsh -NoProfile -File tools/validate.ps1 -AllExamples` includes headless
post-processing validation. Adding `-Runtime` exercises r3d effect rendering
and baseline restoration. Linux runtime validation requires a desktop or Xvfb.
