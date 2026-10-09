# Stable R3D directional shadows, SSAO, and atmospheric composition

This is an altered build of R3D's native light, shader, and draw modules. The exact
changes are in [stable-projection.patch](stable-projection.patch),
[receiver-plane.patch](receiver-plane.patch),
[ssao-reconstruction.patch](ssao-reconstruction.patch), and
[pre-transparency.patch](pre-transparency.patch). Rune's bridge loads the included
objects on Windows AMD64 and Linux AMD64. They replace three members of the
bundled native archive without modifying the r3d-odin submodule or its bindings.
Other targets retain the upstream shadow and screen-space sampling behavior.

R3D fits directional shadows around a sphere centered halfway along the camera's
view. Turning the camera moves that sphere and its caster clipping planes.
Distant objects can enter or leave the shadow volume, changing shadows on
stationary surfaces. Texel snapping alone does not prevent this coverage change.

The replacement centers the sphere at the camera position, with a radius large
enough to contain the far-plane corners in every orientation. Camera rotation
now leaves the shadow matrix and caster volume unchanged. Camera movement still
follows the player with upstream texel snapping. Light direction, FOV, aspect
ratio, and shadow range changes still update the projection. A 70-degree 16:9
view uses approximately 13% fewer texels per world
unit than upstream in return for consistent coverage in every direction.

Directional surface sampling corrects each comparison depth to the receiver
plane at the sampled texel center. A grazing surface otherwise compares several
different depths with one reference, producing stripes; raising the bias hides
those stripes but can also remove shadows cast by small objects. Each existing
Vogel tap uses four weighted, exact-center comparisons to preserve bilinear
filtering. The analytic plane calculation uses geometry normals, including the
existing geometry-normal buffer for deferred rendering, independently of
material normal maps. Degenerate and nonfinite planes fall back to the authored
bias. A half D16 quantization step covers shadow-depth rounding.

Spot/point shadows and volumetric directional samples retain the upstream
sampling. Map formats, sizes, update modes, and native layouts are unchanged.
Surface directional sampling issues 32 texture comparisons instead of eight
hardware-filtered lookups; adjacent taps reuse depth texels, but this increases
shader work and should be included in GPU profiling.

R3D calculates SSAO from a half-resolution depth pyramid that selects one of
four full-resolution pixels in each block. The replacement reconstructs each
view position at that selected pixel, matching the selected normal, instead of
placing its depth at the block center. The existing frame uniform provides the
exact full-resolution dimensions, including odd-sized render targets. Samples
outside the texture or without finite geometry contribute no occlusion.
The existing selector sampler slot is refreshed when normal buffers are bound;
native structure layouts and public APIs remain unchanged.

The shared ambient-effect upsampler now normalizes depth weights without an
epsilon dilution. Previously all four exponential depth weights could become
very small on distant or grazing surfaces. Replacing their sum with an epsilon
turned a white SSAO buffer into dark ambient shading as the lens changed.
Subtracting the smallest depth error among taps with positive bilinear support
keeps at least one weight finite and preserves their relative values. Dividing
by their actual positive sum preserves constant input values. SSIL and SSGI use
the same corrected interpolation weights, so their indirect radiance no longer
fades because of numerical rejection alone. The sampling and lighting settings
remain authored values; animated lenses can still use Rune's separate
`ssao_reference_fovy` screen-radius correction.

The draw module provides a Rune-owned screen shader chain after opaque surfaces,
including unlit geometry, and before transparent blending. Rune's bridge orders
the moon disk, screen-space shafts, and height fog in this chain; volumetric
clouds apply height fog at their actual ray-march sample distances. Public
`SCENE` screen effects still run after transparent rendering. The chain stores
at most four shader pointers outside
the pinned native core state, preserving the public screen-stage enum and all
private module layouts. With an empty chain, the original pass order is retained.
Scene-target swaps return the processed image to transparent rendering, and
transparent surfaces continue to test opaque depth without writing it.

## Rebuild

The build shares Rune's exact R3D, raylib header, and Zig pins in
[sources.json](../r3d-importer/sources.json): R3D
`86303391c92e32418181a8133848a15ba02f060d`, r3d-odin
`66315303455641dc4f097630c14d3adb56ba2a48`, and Zig 0.15.2.
The private core and shader states use the pinned CMake defaults recorded in
[r3d_config.h](r3d_config.h), including `R3D_MAX_SCREEN_SHADERS=4`. Rebuild and
revalidate all three objects when upgrading the bundled native library. The build
applies the four patches in the order listed above.

Ordinary Odin builds use the checked-in objects. Rebuilding exports the pinned
revision into a fresh directory under `build/`, verifies the raylib header
hashes (including `rlgl.h`) and compiler version, and applies only the recorded
patches. It preserves the source checkout and publishes objects only after all
requested builds pass.
Python 3 is required for the pinned upstream GLSL embedding scripts; no Python
packages are required. Ordinary builds do not need Python or Zig.

From the repository root on Windows:

```powershell
.\tools\build_r3d_shadows.bat --r3d-source path/to/r3d --raylib-headers path/to/headers --zig path/to/zig --python path/to/python --target All
```

`--target All` builds Windows and Linux objects using the installed Windows SDK
and MSVC headers for the Windows target. On Linux use
`sh tools/build_r3d_shadows.sh` with the same arguments and `--target Linux`.
No Assimp source checkout is required.
The header generator indexes only shader entry points and rejects missing
version directives; include fragments such as `include/user/scene.vert` must
never replace the same-named scene entry point.

## Validation

```powershell
odin build tools/light_shadow_validation -o:none -thread-count:2 -collection:rune=rune -collection:r3d=third_party/r3d-odin -linker:msvc -out:build/light_shadow_validation.exe
./build/light_shadow_validation.exe --runtime
odin build tools/shadow_render_probe -o:none -thread-count:2 -collection:rune=rune -collection:r3d=third_party/r3d-odin -linker:msvc -out:build/shadow_render_probe.exe
./build/shadow_render_probe.exe build/shadow-render-probe
```

The runtime test checks bit-exact shadow matrix invariance under camera
rotation, coverage of all far-plane corners across 2,592 combinations, native
state-layout agreement, and manual map/matrix update synchronization alongside
existing light/profile tests. Windows runtime validation passes. The Linux
object is cross-compiled; Linux runtime verification remains required.

The render probe compares shadows enabled/disabled in actual captured pixels,
including small floor/facade casters and illuminated grazing receivers. This
checks visible shadow contrast and self-occlusion separately from matrix
stability.

The SSAO [lens probe](../../tools/ssao_fov_probe/README.md) checks contact
shading through FOV animation. The separate
[upsampling probe](../../tools/ssao_upsample_probe/README.md) checks distant,
grazing floor surfaces through even, odd, and portrait render sizes, comparing
raw white SSAO with the final shaded output. A clean raw buffer must not darken
the corresponding surface during upsampling.

The [atmosphere checks](../../docs/cloud-volumes.md#validation) provide focused
Windows/Linux build and runtime commands for cloud depth, both height-fog
layers, moon/fog composition, and screen-space shafts. Windows runtime checks
pass; the Linux draw object is cross-compiled, with Linux runtime verification
still required.

R3D's [zlib license](../r3d-importer/LICENSE.r3d) and the
[raylib/raymath notices](../r3d-importer/README.md#notices) apply to this altered
build. Keep those notices with distributed native objects and the existing
bundled library notices in [THIRD_PARTY.md](../../THIRD_PARTY.md).
