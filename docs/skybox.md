# Skyboxes

Rune's optional r3d bridge renders `Skybox` components from scenes, prefabs, or
Odin. No Transform is required. An empty component gives a procedural sky:

```json
{"id": "sky", "components": {"Skybox": {}}}
```

Use a project-relative image for an HDR or LDR sky:

```json
"Skybox": {
  "mode": "cubemap",
  "texture": "assets/skies/day.hdr",
  "layout": "panorama",
  "rotation": [0, 45, 0],
  "energy": 1
}
```

Image formats are `.hdr`, `.png`, `.bmp`, `.gif`, `.qoi`, and `.dds`. Layouts are
`auto_detect` (default), `panorama` (equirectangular), `line_vertical`,
`line_horizontal`, `cross_three_by_four`, and `cross_four_by_three`.
Use image dimensions appropriate to the selected layout.

Procedural skies need no image asset:

```json
"Skybox": {
  "mode": "procedural",
  "resolution": 256,
  "procedural": {
    "sky_top_color": [32, 100, 185, 255],
    "sky_horizon_color": [194, 219, 238, 255],
    "sun_direction": [-1, -0.4, -1],
    "sun_size": 3
  }
}
```

Missing fields retain defaults, including nested procedural fields. Colors are
RGBA bytes. `rotation` and `sun_size` use degrees. Resolution is the procedural
cubemap face size: a power of two from 16 through 2048. All fields and defaults
appear in [the schema](../schemas/skybox.schema.json).

Set `procedural.sun_enabled` to `false` to remove the procedural sun disk and
halo while keeping the sky and ground gradients:

```json
"Skybox": {
  "mode": "procedural",
  "procedural": { "sun_enabled": false }
}
```

It defaults to `true`. Other sun settings are preserved for re-enabling it.
This option affects the original procedural mode; atmospheric mode still uses
its referenced directional light. Runtime edits also work:
`set sky Skybox.procedural.sun_enabled false`.

## Atmospheric sky with a directional sun

Set `mode` to `atmospheric` and reference a scene entity containing a
`DirectionalLight`:

```json
{
  "id": "sky",
  "components": {
    "Skybox": {
      "mode": "atmospheric",
      "resolution": 256,
      "atmosphere": {
        "sun": "sun",
        "rayleigh": 1,
        "mie": 1,
        "mie_anisotropy": 0.8,
        "sun_size": 0.53
      }
    }
  }
}
```

```json
{
  "id": "sun",
  "components": {
    "DirectionalLight": {
      "direction": [0.6, -0.5, 0.6],
      "color": [255, 255, 255, 255],
      "intensity": 1
    }
  }
}
```

The sun follows the light's world-space `direction`, `color`, and `intensity`.
Light direction describes the direction rays travel, so the visible sun is in
the opposite direction. `Transform.rotation` does not aim Rune directional
lights. `Skybox.rotation` is ignored in this mode to keep the sun and horizon
aligned with the world. Atmospheric parameters do not modify the light itself.

Rayleigh scattering produces a blue sky and sunset extinction; Mie scattering
produces aerosol haze and the sun's halo. This is a ground-level, single-scattering
approximation with exponential air density, using the optical-depth integration
approach described in [GPU Gems 2, chapter 16](https://developer.nvidia.com/gpugems/gpugems2/part-ii-shading-lighting-and-shadows/chapter-16-accurate-atmospheric-scattering).
It models an Earth-sized atmosphere from a fixed observer altitude of 100 metres.
Camera translation does not change this altitude. It does not add clouds, stars,
volumetric fog, or atmospheric attenuation to scene geometry.

| Field | Default | Meaning |
| --- | --- | --- |
| `sun` | Required in atmospheric mode | Scene entity ID with a DirectionalLight. |
| `moon` | `""` | Optional DirectionalLight entity ID; empty disables the moon. |
| `moon_size` | 0.52 | Full moon disk angular diameter in degrees, 0.1–20. |
| `night_color` | `[30,45,85,255]` | Color of the dim night background. |
| `night_energy` | 0.3 | Night background brightness; zero disables this fill. |
| `rayleigh` | 1 | Molecular scattering multiplier, 0–10. |
| `mie` | 1 | Aerosol scattering multiplier, 0–10; higher values increase haze. |
| `mie_anisotropy` | 0.8 | Forward scattering, 0–0.95; higher values tighten the halo. |
| `sun_size` | 0.53 | Sun disk angular diameter in degrees, 0.1–20. |
| `ground_color` | `[45,53,59,255]` | Ground color below the horizon, lit by the sun, moon, and night fill. |

`energy` controls overall sky brightness. The light's intensity is multiplied by
20 for the atmosphere's radiance scale (and bounded at 10,000 before scaling).
Use a `PostProcessing` tone mapper such as `aces` for its bright sun and horizon.
Move the light toward a horizontal direction for sunset; point it upward to put
the sun below the horizon. Disabling the light or an ancestor, or setting its
intensity to zero, removes its atmospheric illumination; moonlight and night fill remain. AmbientLight and other
scene lights continue to illuminate scene geometry independently.

A missing sun entity, wrong component type, or invalid light direction produces an
asset diagnostic and uses the background color. The reference resolves again
each frame, so adding or repairing the light recovers automatically. Named
references are resolved at runtime, including entities created by gameplay.

The shader is embedded in the engine. Atmospheric cubemaps are generated once
and updated in place when the referenced light or atmosphere parameters change.
Camera movement and `energy` changes do not regenerate them. Generation uses
16 view samples and 8 light samples per view sample, per contributing source;
an absent or disabled moon skips its scattering pass. Lower `resolution` for rapidly
animated lights. Changing resolution recreates the cubemap. Shader and cubemap
resources are released when changing modes, removing the sky, or shutting down.

### Night sky and optional moon

The default night fill keeps the sky dim blue after sunset, even without a moon.
It fades in through twilight and disappears by sunrise. This is an artistic
background contribution, not physical airglow or illumination of scene objects.
Set `night_energy` to zero for an unfilled night sky.

To add a full moon, set `atmosphere.moon` to a second directional light's entity ID:

```json
"atmosphere": {"sun": "sun", "moon": "moon", "moon_size": 1, "night_energy": 0.3}
```

```json
{"id": "moon", "components": {"DirectionalLight": {
  "direction": [-0.6, -0.5, -0.6],
  "color": [180, 205, 255, 255],
  "intensity": 0.03
}}}
```

The moon uses the same light-direction convention and atmospheric scattering as
the sun. Its light controls both the visible disk and moonlit haze, and also lights
scene geometry as an ordinary DirectionalLight. It is a plain full disk; lunar
phases and surface textures are not modeled. The example rotates it opposite the
sun; games can animate both directions independently.

The moon disk is evaluated at the scene's render resolution with an antialiased
edge, independently of `Skybox.resolution`. The cubemap stores only its atmospheric
haze. This keeps small moons sharp without increasing the cost of atmospheric
integration across the whole sky. The disk retains atmospheric extinction, sky
energy, fog influence, bloom, and tonemapping. Scene depth masks foreground objects;
transparent materials that do not write depth do not mask this pass.
The bridge uses r3d's `SCENE` screen-shader stage for the disk during `draw_scene`
and clears it afterward; custom screen effects should use the other stages.

Set `moon` to `""` to remove it from the sky, or disable its light entity to remove
both its sky contribution and scene lighting. An invalid optional moon reports a
diagnostic and renders the rest of the sky; repairing it recovers automatically.
Runtime commands include `set sky Skybox.atmosphere.night_energy 0.15` and
`set sky Skybox.atmosphere.moon ""`.

## Selection and lifecycle

The enabled Skybox on the active Camera3D wins. Otherwise the lowest-handle
enabled non-camera Skybox wins. Disabled entities (including disabled parents)
are skipped. If no sky is selected, the bridge uses its usual background color.
The sky is a visual background; scene lights still control illumination. It does
not automatically generate image-based lighting. The original `procedural` mode
has its own sun settings; `atmospheric` follows its referenced DirectionalLight.
Post-processing and fog apply to the sky as usual.

```odin
sky := ecs.default_skybox()
sky.rotation[1] = 45
ecs.add(world, registry, entity, sky)
// Later, ecs.get(world, entity, ecs.Skybox) and ecs.set(world, entity, sky).
```

The runtime inspector, `set sky Skybox.rotation [0,90,0]`, prefabs, and scene hot
reload use the same validated component. Invalid edits leave current values
intact. Image timestamps are polled with other development assets. A failed
reload retains the previous image and reports an asset diagnostic; a failed
initial load or a failed switch to another source uses the background color.
Repairing the image retries on the next timestamp change.

The bridge owns one active GPU cubemap, reuses it between frames, and releases
it when switching sources, disabling/removing the last sky, or shutting down.
Rotation and energy edits do not regenerate the image. Procedural settings or
resolution edits regenerate it. Use `r3d_bridge.draw_scene[_ex]` to render and
`r3d_bridge.shutdown` before closing the window to release resources.

Run [Skybox 3D](../examples/skybox_3d) for a complete example.
