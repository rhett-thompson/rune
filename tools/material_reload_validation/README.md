# Selective material reload validation

From the repository root on Windows:

```powershell
./tools/odin.ps1 -OdinArguments @('build','tools/material_reload_validation','-collection:rune=rune','-collection:r3d=third_party/r3d-odin','-linker:msvc','-out:build/material_reload_validation.exe')
./build/material_reload_validation.exe --runtime
```

On Linux use `sh tools/odin.sh build` with the same collections, omit the MSVC
linker flag, and choose an executable output without `.exe`.

The default run explicitly skips GPU work. `--runtime` creates a hidden window,
tiny file textures, material JSON, and a surface shader under ignored
`build/material-reload-validation/`. A working OpenGL display backend is required.

The fixture injects a sentinel into material B's GPU texture, then previews A.
B must keep the sentinel, shader pointer, generated ORM handle, and fast cache
hit. This verifies resource reuse without relying on numeric OpenGL names, which
drivers may reuse after deletion. It then verifies B's own texture and shader
edits reload, invalid shader edits retain the working material, one cache path
respects distinct sampler variants, retired ORM textures survive held leases,
and final release/replacement reclaims unused entries. The invalid shader case
deliberately emits a warning and asset diagnostic.
