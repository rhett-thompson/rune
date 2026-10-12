# Material surface shaders

Material JSON can attach a project-relative r3d surface hook:

```json
{
  "lighting": true,
  "surface_shader": "assets/shaders/moving_surface.glsl",
  "surface_shader_time": true
}
```

The GLSL file defines `void vertex()` and/or `void fragment()`. Rune keeps r3d's
normal lighting and material pipeline; a hook changes surface inputs and outputs.
For example:

```glsl
#pragma usage opaque shadow
uniform float u_time;

void vertex() {
    TEXCOORD += vec2(0.01, 0.0) * u_time;
}

void fragment() {
    EMISSION *= 0.95 + 0.05 * sin(u_time + TEXCOORD.x * 6.283185);
}
```

Vertex `POSITION`, `NORMAL`, and `TEXCOORD` are mutable. The fragment hook runs
after standard albedo, emission, normal, and ORM maps have been sampled. It can
read or modify `ALBEDO`, `ALPHA`, `EMISSION`, `NORMAL_MAP`, `ROUGHNESS`,
`METALNESS`, `OCCLUSION`, and `SPECULAR`. `NORMAL_MAP` is an encoded tangent-space
normal in the 0–1 range. The usual PBR normal conversion and lighting run after
the hook. The r3d functions `SampleAlbedo`, `SampleNormal`, `SampleEmission`,
`SampleOrm`, and `FetchMaterial` support resampling the existing maps at other UVs.

`surface_shader_time` defaults to false. Set it to true and declare
`uniform float u_time` to receive elapsed seconds every draw, with no texture
regeneration or re-upload. By default this follows raylib's `GetTime()`. Games
can pass `Scene3D_Settings{material_time=seconds, material_time_override=true}`
to use their simulation clock, pause the animation, or capture a reproducible
frame, including time zero. All time-enabled materials share that draw's clock.

Rune owns the compiled shader in its per-material cache. Material hot reload also
watches the shader source. A failed source reload keeps the last working material
and reports a diagnostic; a subsequent source edit retries. Removing
`surface_shader` releases the shader and returns to the standard material.
Custom shader materials use ordinary mesh submission rather than Rune's prop
instancing path. For `material_from_data`, provide a stable nonempty material
cache key so the bridge can own and release the shader.

The project validator checks shader references; compilation requires a graphics
context. Run `tools/material_shader_validation` with `--runtime` to exercise GPU
clock updates, cache reuse, source reload, failure retention, and shader release.
