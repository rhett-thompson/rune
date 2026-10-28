# Asynchronous material reload validation

The default mode runs policy checks without a graphics context. `--runtime`
uses a hidden raylib window and the optional R3D bridge to check real texture
pixels, native sRGB formats, bounded job submission, stale results, and resource
lifetimes. It creates owned fixtures and a report under ignored `build/`.

Build from the Rune root with the pinned compiler wrapper, Rune/R3D collections,
and the Windows MSVC linker:

```powershell
./tools/odin.ps1 -OdinArguments @(
    'build', 'tools/material_async_validation',
    '-collection:rune=rune', '-collection:r3d=third_party/r3d-odin',
    '-linker:msvc', '-out:build/material_async_validation.exe'
)
./build/material_async_validation.exe
./build/material_async_validation.exe --runtime
```

On Linux, use `sh tools/odin.sh` with the same build/collection arguments, omit
`-linker:msvc`, and choose an output filename without `.exe`. A display and the
matching native dependencies are required for runtime mode.

The runtime checks cover:

- Synchronous first procedural/image loads while the Rune worker is blocked.
- Old GPU pixels retained while a replacement is queued or the queue is full.
- Completion becoming eligible only at a new pump boundary.
- Preview A superseded by B before A can upload.
- Corrupt PNG and JPEG payload retention, retry suppression, and valid repair.
- RGBA PNG and RGB JPEG pixel channels and native sRGB texture storage.
- At most one material replacement installed per pump boundary.
- Ordinary `bridge.draw_scene` on a stationary two-cube instancing batch:
  cached frames stop calling material getters while work is blocked, then
  completion wakes the cache and changes rendered pixels without manual getter
  or pump polling by the test.
- A fully occupied foreign worker/queue rejects every material submission;
  ordinary cached draws retry and install after capacity becomes available.
- A stale completion is discarded after preview A becomes B; ordinary cached
  draws subsequently admit and display B without manual getter polling.
- Successful repaired installs clear the generic asynchronous material failure
  diagnostic, allowing a later failure to be reported again.
- `material_reload_synchronous` installs through ordinary drawing immediately
  while a blocked worker pool remains attached.
- Ordinary terrain drawing after an image-only edit: unchanged material data
  hashes still produce new layer/packed atlases and rendered pixels after the
  GPU commit, without rebuilding terrain geometry.
- Pending or failed terrain-layer decoding preserves both atlas identities and
  rendered pixels; a successful repair replaces them and clears its diagnostic.
- Two live managers with identical material data, dependency fingerprints, and
  path revisions can still own different observed source pixels. Ordinary draws
  switch correctly between them; a blocked request owned by the old manager
  cannot overwrite or starve the active manager's distinct preview.
- Bridge shutdown draining an accepted procedural request before cleanup.
- Synchronous replacement with no pool attached.

The installed raylib build does not provide JPEG file import/export. The test
therefore starts a PNG-backed cache entry, then writes JPEG bytes to that same
`.png` path using the vendor stb writer on the main thread. The isolated Rune
decoder detects payload format independently of the suffix. This exercises RGB
JPEG background preparation without claiming legacy raylib JPEG support. A
second corrupt/repair cycle starts from that installed JPEG result.

`build/material_async_validation_report.json` records the fixture directory,
GPU/version, completed checks, and observed shutdown wait. That wait is a
lifetime diagnostic from this tool's compilation settings, not a performance
benchmark. The runtime checks passed on Windows AMD64 with the pinned October
Odin compiler, MSVC, static raylib 6, GLFW/Win32, and an NVIDIA GTX 1060/OpenGL 3.3.
Linux GPU behavior remains unverified by this tool's recorded Windows run.
