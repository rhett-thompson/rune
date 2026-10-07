# Cloud volumes

`CloudVolume` is a generic participating medium rendered by the optional r3d
bridge. Core ECS, serialization, and validation remain independent of r3d.
Attach it to an entity with a `Transform`; positive XYZ scale gives the full
dimensions of a noise-eroded ellipsoid. Rotation and existing parent transforms
apply normally. It creates no collision, casts no shadows, and needs no
`MeshRenderer`, material file, or sprite texture.

```json
{
  "id": "cloud",
  "components": {
    "Transform": {"position": [0,80,-400], "scale": [200,80,160]},
    "CloudVolume": {
      "density": 0.035,
      "noise_scale": 90,
      "coverage": 0.55,
      "steps": 32
    }
  }
}
```

All fields are optional and use `ecs.default_cloud_volume()` defaults. Use
`ecs.add`, `ecs.get`, and `ecs.set` with `ecs.CloudVolume` in Odin. Invalid
JSON or typed writes fail without replacing a valid component. See
[`cloud-volume.schema.json`](../schemas/cloud-volume.schema.json) for fields
and ranges. Density is extinction per world unit; zero renders empty space.
Color and shadow_color use RGB bytes, with alpha reserved. Coverage controls
noise erosion; noise_scale is the world-space repetition wavelength. Steps
from 8 to 96 trade cost for smoothness; 24–32 suit distant banks. Set
noise_offset from the game's simulation clock to animate density reproducibly.

The renderer clips rays against an analytic ellipsoid and opaque scene depth,
integrates Beer–Lambert opacity, and approximates directional lighting with a
short coarse density probe toward the strongest enabled directional light.
It supports views from inside a volume. It shares one generated, filtered
3D-noise slice atlas and one shader program, with independent uniform aliases
per entity. Aliases are released on removal or world generation changes;
shutdown frees the shared GPU resources. Disabled entities stop drawing.

This is a bounded cloud renderer: overlapping volumes use r3d's transparent
draw ordering. It does not combine overlapping densities, cast volumetric
shadows onto geometry, or perform multiple scattering. Transparent objects
do not stop rays. Post-processing still applies through the existing scene
chain; fog uses opaque depth, as it does for other transparent materials.

Validate data with `.\tools\validate.bat --all-examples`. The focused
`build/cloud_volume_validation --runtime` (add `.exe` on Windows) checks
opacity, foreground occlusion, a solid object inside a cloud, views inside a
volume, zero density, and alias cleanup on a real graphics context.
