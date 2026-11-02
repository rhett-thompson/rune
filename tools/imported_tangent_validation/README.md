# Imported tangent GPU regression

This hidden-window validator loads a generated OBJ through Rune's production
`ModelRenderer` importer. Its source face has an explicit +X normal and no UVs.
It compares runtime yaw 0, −90, +90, and −90 with nonuniform scale against OBJ
files containing the equivalent baked positions and normals. Each case runs
with default submission/cache settings and ordinary uncached submission.

The regression occurs when a no-UV import receives a fallback tangent parallel
to its normal. R3D's tangent frame then produces a nonfinite lighting normal.
Rotating the model can make a correctly oriented face render black while an
equivalent model with its rotation baked into the asset renders normally.

From Rune's root on Windows, build and run separately:

```powershell
./tools/odin.ps1 -OdinArguments @(
    'build', 'tools/imported_tangent_validation', '-o:none', '-thread-count:2',
    '-collection:rune=rune', '-collection:r3d=third_party/r3d-odin',
    '-linker:msvc', '-out:build/imported_tangent_validation.exe'
)
./build/imported_tangent_validation.exe --runtime
```

On Linux, use `sh tools/odin.sh build` with the same collection flags, omit
`-linker:msvc`, and launch the executable after compilation finishes. The tool
requires an actual OpenGL context; it runs GPU validation by default, and accepts
`--runtime` for consistency with other Rune validators.

Generated fixtures, PNGs, and `report.json` remain in the ignored
`build/imported-tangent-validation` directory. An optional positional argument
selects another output directory. `--observe` records a broken baseline without
asserting the final pixel predicates; asset/shader load failures still assert.

For each imported/baked pair, the validator requires more than 20/255 luminance
gain from a point light, less than 5/255 with it disabled, and less than 4/255
difference between the lit images' central samples. A separate surface shader
reconstructs R3D's lighting normal from the actual GPU tangent frame and default
normal map. It emits green only when that normal is finite, unit length, and
aligned with the geometric normal; a failed check emits red. The 5×5 central
sample must be green. No game materials, grading, shadows, ambient lighting,
screen effects, or CPU light occlusion participate.

The normal diagnostic uses ordinary model submission because custom surface
shaders do not use prop instancing. The default lighting captures exercise the
normal production submission selection; this single-model fixture does not
claim to force a multi-instance prop batch. This is a focused imported no-UV
regression, not general coverage of normal-mapped or skinned assets.

On 2026-11-02, all eight cases and the two focused importer tangent unit tests
passed on Windows AMD64/MSVC, Odin `84bc3fc`, OpenGL 3.3 and an NVIDIA RTX 3090.
The rebuilt Low Heaven cabin also rendered its previously black rear wall
correctly. Linux GPU behavior remains unverified.
