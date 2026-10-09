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

On Windows/Linux AMD64, the bridge fits directional shadows around the camera
position with enough coverage for the far-plane corners in every orientation.
Turning the camera leaves the shadow matrix and caster clipping volume unchanged,
so distant casters no longer appear or disappear merely because of a look turn.
Camera movement, FOV, aspect ratio, light direction, and shadow range changes
still alter the fit when the map refreshes. The shadow volume remains finite;
map size, distance fading, and texel snapping retain the backend's behavior.
See the [native patch and rebuild instructions](../third_party/r3d-shadows/README.md).

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
their sampling cost. The bundled r3d backend fixes resolution at 2048² for
point/spot lights and 4096² for directional lights; profiles therefore do not
expose map resolution. Disabling shadows retains native map memory for reuse.
