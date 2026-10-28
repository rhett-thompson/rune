# Shadow profiles

`DirectionalLight`, `PointLight`, and `SpotLight` can share a project-relative
JSON shadow profile. Color, intensity, range, and specular remain on each light.

```json
"PointLight": {
  "color": [255, 215, 164, 255],
  "intensity": 0.5,
  "range": 11,
  "shadow_profile": "assets/shadows/important-lamp.shadow.json",
  "shadow_overrides": { "softness": 2 }
}
```

The referenced `.shadow.json` file:

```json
{
  "$schema": "../../schemas/shadow-profile.schema.json",
  "enabled": true,
  "softness": 1.5,
  "opacity": 1,
  "depth_bias": 0.006,
  "slope_bias": 0.01,
  "update_mode": "interval",
  "interval_ms": 250
}
```

| Field | Meaning | Default |
| --- | --- | --- |
| `enabled` | Whether the light casts shadows | `true` |
| `softness` | Filter radius in texels; zero disables filtering | `1` |
| `opacity` | Shadow strength, from 0 to 1 | `1` |
| `depth_bias` | Nonnegative depth offset | `0.005` |
| `slope_bias` | Nonnegative slope-scaled offset | `0.01` |
| `update_mode` | `continuous`, `interval`, or `manual` | `continuous` |
| `interval_ms` | Positive integer milliseconds between interval updates | `250` |

Profiles supply all shadow settings, with defaults for omitted fields. When a
profile is selected, legacy flat fields (`shadows`, `shadow_softness`, etc.) are
ignored. Without a profile, existing light JSON retains its behavior. Clearing
`shadow_profile` to `""` restores those legacy settings and the native update
policy (currently interval updates every 16ms).

`shadow_overrides` accepts the same seven fields. Omitted or `null` values
inherit; explicit `false` and `0` override. Overrides also work without a profile.
Unknown fields, negative/nonfinite numbers, opacity above 1, and invalid modes
are rejected. Profile files do not accept null settings.

Typed lights expose `shadow_profile: string` and `shadow_overrides: shadows.Overrides`:

```odin
import "rune:shadows"
light.shadow_overrides.enabled = false
light.shadow_overrides.softness = f32(0)
light.shadow_overrides.enabled = {} // inherit again
ecs.set_point_light(world, entity, light)
```

The world retains profile strings and validates overrides for typed setters,
JSON mutation, snapshots, and save/reload. Runtime console edits use existing
component paths, including unset override fields:

```text
set lamp PointLight.shadow_profile "assets/shadows/ambient-lamp.shadow.json"
set lamp PointLight.shadow_overrides.enabled false
set lamp PointLight.shadow_overrides.enabled null
set lamp PointLight.shadow_overrides.update_mode "continuous"
```

`shadows_disabled` on each light is an independent disable switch; it leaves
profile selection and overrides intact. The renderer's `Context.shadows_disabled`
disables every light without modifying components. Clearing either switch
restores the effective settings on the next renderer sync.

Profiles load through `assets.shadow_profile` and are cached by path. Editing a
loaded file updates every referencing light at the next hot-reload poll
(`hot_reload.shadow_profiles`, default true; also requires `hot_reload.enabled`).
Invalid or deleted files report an asset diagnostic and retain the last working
profile. If the first load fails, shadows stay disabled. Lights keep their native
handles when settings change. New maps, re-enabled shadows, or changed effective
settings request an initial map update.

Use continuous updates for moving lights/casters and camera-centered sun maps.
Interval updates reduce recurring work but can lag behind moving objects.
Manual maps require explicit refreshes after moving a light or its casters, or
changing scene geometry or the camera's directional-shadow coverage:

```odin
// After the renderer has synchronized this entity at least once:
r3d_bridge.request_shadow_update(renderer, entity)
```

`DirectionalLight.range` controls directional shadow coverage through R3D's
public `SetLightRange` API; it does not limit the sun's illumination distance.
Reducing this range dedicates the same map to nearby geometry. The backend
already fades directional shadows between 75% and 100% of the range, measured
along camera view depth, and fades at the last 5% of the map's projected bounds.
For example, a range of 64 keeps the distance fade between 48 and 64 scene units.
This is a view-depth fade, so turning toward a receiver can change its shadow
strength even when the shadow map projection remains unchanged.

R3D exposes no independent fade start/end, custom directional projection or
bounds, cascade controls, or explicit shadow center. Setting a directional
light's position does not move its shadow coverage. The projection also retains
the backend's fixed 100-unit depth extension toward potential casters.

On Windows/Linux AMD64, the bridge fits directional shadows around the camera
position with enough coverage for the far-plane corners in every orientation.
Turning the camera leaves the shadow matrix and caster clipping volume unchanged,
so distant casters no longer appear or disappear merely because of a look turn.
Camera movement, FOV, aspect ratio, light direction, and shadow range changes
still alter the fit when the map refreshes. The shadow volume remains finite;
map size, distance fading, and texel snapping retain the backend's behavior.
See the [native patch and rebuild instructions](../third_party/r3d-shadows/README.md).

The fitted radius is `range * sqrt(1 + tan(fovy / 2)^2 * (1 + aspect^2))`,
with a square projected span of twice that radius. At 70 degrees and 16:9, a
4096-pixel map covers about 628 units for range 180 (0.153 units per texel),
or 223 units for range 64 (0.054 units per texel). Wider FOVs and aspect ratios
spread the fixed map over a larger area. Camera movement remains texel-snapped;
FOV/aspect changes can still change sampling density.

On those targets, directional surface comparisons follow the receiver plane
at each sampled texel center. This suppresses grazing-angle stripes without
requiring a large bias that also removes small contact shadows. Geometry normals
are used independently of material normal maps. Spot/point shadows and volume
samples retain the backend's filtering. The surface correction performs four
explicit comparisons per filter tap, increasing directional sampling work.

Directional/spot bias values are in normalized map depth, so their world-space
effect grows with the projection's depth span. Prefer a small bias and validate
both illuminated receiver surfaces and nearby small casters; a clean surface
alone can also mean its real shadows have been biased away.

Point-light depth and slope bias values use radial world distance in scene
units. Allow for the cubemap's depth quantization and filter footprint when
tuning a wide-range point light. Verify both flat receivers and real caster
shadows at the intended distances.

Changing map update frequency does not reduce the number of enabled maps or
their sampling cost. Configure map resolution in `project.json`:

```json
"render_3d": {
  "shadows": {
    "directional_resolution": 2048,
    "spot_resolution": 1024,
    "omni_resolution": 512
  }
}
```

Omitted fields retain defaults: `directional_resolution` is `4096`, and
`spot_resolution` / `omni_resolution` are `2048`. Values must be integer pixel
dimensions from 2 through 8192; powers of two are conventional but not required.
Each value is shared by all lights of that type. Omni resolution is the size of
each point-light cubemap face. The backend clamps values to the GPU's texture
size limit, which can be lower than Rune's upper bound. Larger maps increase
memory and map-rendering work; halving the side length quarters the texel count.

The game owns its optional 3D renderer. Forward the loaded project settings
when initializing it, after Rune has created the graphics window:

```odin
renderer, ok := r3d_bridge.init(game.project_directory,
    game.project.window.width, game.project.window.height, game.project.render_3d)
```

For a renderer without a loaded project, start with
`render.default_settings_3d()` from `rune:render`, change the desired fields,
and pass that value as the fourth argument. Omitting the argument preserves the
4096/2048/2048 defaults. Invalid typed settings make initialization fail before
native renderer access. The bridge sets all three native `SetHint` values before
`R3D_Init`; resolution changes require shutting down and reinitializing the
renderer. Project hot reload does not resize existing maps. There is no per-light
resolution control, so shadow profiles do not expose map resolution. Disabling
shadows retains native map memory for reuse.

The settings and validation live in `rune/render/settings_3d.odin`; their native
application is in `rune/r3d_bridge/r3d_bridge.odin`. A focused native check can run
the `r3d_bridge.renderer_shadow_settings_reach_native_maps_and_reset_on_reinit`
test with `RUNE_SHADOW_MAP_GPU_TESTS=true`, `ODIN_TEST_THREADS=1`, the usual Rune
and R3D collection flags, and the platform linker. It requires a graphics context
and checks native hint readback, enabled map allocation for all three light
types, and default restoration after renderer reinitialization. It does not
measure shadow quality or GPU performance.

On 2026-10-28, that native check passed on Windows AMD64 with the pinned Odin
toolchain, MSVC, a hidden GLFW/Win32 window, OpenGL 3.3, and an NVIDIA GTX 1060.
It verified 256/128/64 hints and default restoration. Actual texture dimensions
are not exposed by the public R3D API; Linux runtime behavior remains untested
for these startup settings.
