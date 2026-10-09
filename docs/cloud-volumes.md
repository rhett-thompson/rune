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

On Windows/Linux AMD64, the bridge renders the
[moon disk](skybox.md#night-sky-and-optional-moon),
[screen-space light shafts and height fog](post-processing.md) after opaque
surfaces, including unlit geometry, and before transparent blending. The order
is moon, shafts, then height fog. Each cloud ray sample applies both height-fog
layers over its finite camera-to-sample distance. Nearby cloud density receives
foreground fog, while fog farther behind it remains in the transmitted
background. Clouds can cover the moon and shafts through alpha blending without
writing opaque depth. Public r3d `SCENE` screen effects run after the clouds.
Other targets retain the previous `SCENE` atmospheric chain, where height fog
uses the opaque depth behind transparent clouds.

This is a bounded cloud renderer: overlapping volumes use r3d's transparent
draw ordering; their densities are not merged. It does not cast volumetric
shadows onto geometry or perform multiple scattering. Opaque geometry stops
cloud rays; other transparent objects do not. Native `volumetric_fog` is a
separate effect; these height-fog changes do not alter its integration.

## Validation

From the repository root, build and run the focused atmosphere checks on Windows:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
foreach ($tool in 'cloud_volume_validation', 'skybox_validation', 'light_shafts_validation') {
    odin build "tools/$tool" -o:none -thread-count:2 -collection:rune=rune -collection:r3d=third_party/r3d-odin -linker:msvc "-out:build/$tool.exe"
    if ($LASTEXITCODE -ne 0) { throw "Build failed: $tool" }
    & "./build/$tool.exe" --runtime
    if ($LASTEXITCODE -ne 0) { throw "Validation failed: $tool" }
}
```

On Linux AMD64:

```sh
mkdir -p build
for tool in cloud_volume_validation skybox_validation light_shafts_validation; do
    odin build "tools/$tool" -o:none -thread-count:2 -collection:rune=rune -collection:r3d=third_party/r3d-odin "-out:build/$tool" || exit 1
    "./build/$tool" --runtime || exit 1
done
```

Runtime checks require a graphics context; Linux needs a desktop or
[Xvfb](linux.md). Omit `--runtime` for data-only checks. Cloud validation covers
opacity, foreground occlusion, a solid object inside a cloud, views inside a
volume, zero density, and alias cleanup. It also checks nearby clouds against
thick distant height fog, changes in the opaque background distance, fogged
foreground solids, and both height-fog layers, saving
`build/cloud-height-fog-validation.png`. The other checks cover moon/fog
composition and shaft occlusion. The
[native rebuild guide](../third_party/r3d-shadows/README.md) documents the owned
Windows/Linux objects and their pinned sources.
