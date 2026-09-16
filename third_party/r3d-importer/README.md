# Rune's patched R3D importer

This is an altered build of R3D's importer, with the change recorded in
[fbx-pivots.patch](fbx-pivots.patch). Rune's bridge uses it automatically on
Windows AMD64 and Linux AMD64. The checked-in libraries contain only the
importer; they link to the existing bundled Assimp and R3D libraries.

## Fix

Assimp defaults to preserving FBX pivot transforms as extra scene nodes such
as `mixamorig:LeftArm_$AssimpFbx$_Rotation`. R3D's skeleton contains mesh bones,
so its animation loader cannot match those helper nodes and drops their
channels. `Strut Walking.fbx` previously imported only 17 of its 52 channels.

Both file and memory imports now set `AI_CONFIG_IMPORT_FBX_PRESERVE_PIVOTS`
to false using a per-import property store. Assimp folds pivot transforms
into the actual joints. The same policy applies to model loads, animation
loads, reloads, and quality mode. Property stores are released immediately
after import, including on parse failure. Units remain those of the source
asset; the example uses a `0.01` scale for its centimeter-based FBX.

The three entry points are renamed to `Rune_*` at compilation, so they coexist
with the unmodified upstream library. The bridge's `import_model` and
`import_model_animations` helpers use them. For memory assets, use
`r3d_bridge.load_importer_from_memory`, extract the model/animation library
with R3D's `Load*FromImporter` functions, then call
`r3d_bridge.unload_importer`. The extracted resources have independent
lifetimes and use normal R3D unload functions.

The Rune extension in [animation_clips.c](animation_clips.c) imports the first
clip of a separate animation file against a supplied skeleton. It matches
joints by name, ignores unweighted source joints, and copies the mapped tracks
into the model's animation library under an explicit alias. No mesh or skin is
required in the source. Joint names, rest pose, and units must match; this is
not retargeting. See `register_model_animation_source` in the
[animation guide](../../docs/model-animation.md).

Direct calls to `r3d.LoadModel` or `r3d.LoadAnimationLib` still use upstream's
importer. Experimental targets other than Windows/Linux AMD64 retain the
upstream import path. This patch does not add arbitrary animated scene nodes
to R3D's skeleton or implement root-motion application.

## Pinned sources and rebuild

[sources.json](sources.json) pins R3D, Assimp, the raylib headers, and Zig.
The importer uses R3D's private bone-map layout, so **rebuild and revalidate
it when upgrading the r3d-odin submodule**. The pin matches r3d-odin commit
`4813ecbfea503e8bb207a4297bbfc7da7c235a97`.

Ordinary Odin builds use the included archives and need no extra compiler.
To reproduce the archives, install Zig 0.15.2 and obtain local Git checkouts
of [R3D](https://github.com/Bigfoot71/r3d) and
[Assimp](https://github.com/assimp/assimp) containing the pinned revisions.
Download `raylib.h` and `raymath.h` from the pinned
[raylib revision](https://github.com/raysan5/raylib/tree/c1ab645ca298a2801097931d1079b10ff7eb9df8/src)
into one directory.
The build script verifies their SHA-256 hashes and exports the pinned Git
revisions without changing either checkout. It performs no explicit downloads;
a partial Git clone may fetch missing objects when exporting.

From the repository root:

```powershell
./tools/build_r3d_importer.ps1 -R3DSource path/to/r3d -AssimpSource path/to/assimp -RaylibHeaders path/to/headers -Zig path/to/zig -Target All
```

`-Target All` builds both archives on Windows, using installed MSVC headers
and the Windows SDK for the Windows target and Zig's headers for Linux.
On Linux use `-Target Linux`. Build products and compiler caches stay under
`build/`; only completed archives are copied here. Zig is a build tool and is
not shipped with Rune.

## Validation

```powershell
odin build tools/model_animation_validation -collection:rune=rune -collection:r3d=third_party/r3d-odin -out:build/model_animation_validation.exe
./build/model_animation_validation.exe --runtime
```

The runtime validator checks all 52 FBX channels, changing joint poses,
looping, identical file/memory poses in fast and quality modes, malformed
memory input, and reloads that preserve playback and other models' players.
It also checks an animation-only punch, joint remapping, replay, blending,
source/model reloads, failed reload recovery, and rejection of an unrelated
rig, alongside the existing glTF, transition, marker, and reload checks.
Use the platform's executable suffix on Linux.

Windows runtime playback and captured frames were verified. The Linux
archive was cross-compiled; Linux runtime verification is still required.
An Odin Linux cross-check on this Windows host stopped at missing Linux STB
and Box2D toolchain libraries, before checking the application.

## Notices

R3D source is covered by [LICENSE.r3d](LICENSE.r3d), and its embedded uthash
code by [LICENSE.uthash](LICENSE.uthash). Header notices are retained in
[LICENSE.assimp](LICENSE.assimp), [LICENSE.raylib](LICENSE.raylib), and
[LICENSE.raymath](LICENSE.raymath). Keep the existing bundled native library
notices as described in [THIRD_PARTY.md](../../THIRD_PARTY.md).
