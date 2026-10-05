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
changing scene geometry:

```odin
// After the renderer has synchronized this entity at least once:
r3d_bridge.request_shadow_update(renderer, entity)
```

Changing map update frequency does not reduce the number of enabled maps or
their sampling cost. The bundled r3d backend fixes resolution at 2048² for
point/spot lights and 4096² for directional lights; profiles therefore do not
expose map resolution. Disabling shadows retains native map memory for reuse.
