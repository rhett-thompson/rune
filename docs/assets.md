# Asset loading and background reload

Rune's asset manager owns its cached textures, fonts, material definitions,
and related CPU data. Keep asset-manager access and graphics work on the owning
game thread. Cached GPU handles are borrowed and can change after a successful
reload; reacquire them through the manager when needed.

## Engine texture reload

Projects that enable the engine CPU pool with `jobs.worker_count` also use it
for supported raster texture replacements in the 2D asset-manager cache:

```json
"jobs": { "worker_count": 3 }
```

First loads remain synchronous, including a first missing-file result. During
hot reload, the manager keeps returning the last working texture while a worker
reads and decodes a replacement. The worker receives an owned absolute path,
file timestamp, bounded input reservation, and private result/error storage.
It does not access the asset manager, raylib callbacks, renderer state, or GPU.
The isolated decoder is provided by `rune/image_decode` and its private native
library; importing ordinary vendor stb symbols would not isolate raylib's
decoder globals.

At the next frame boundary, the game thread polls completed requests without
waiting, verifies that their source timestamp and cache entry are still current,
and uploads a limited number of results before simulation/rendering. Newer
edits discard obsolete pixels before upload and coalesce into one fresh request
for that path. Queue pressure defers work; it never runs a rejected decode
inline. Successful installs notify material dependencies. Failed reads, invalid
payloads, oversized inputs/results, and failed uploads retain the old texture.
An unsuccessful source timestamp is attempted once until the file changes.

The background decoder supports PNG, JPEG, BMP, TGA, HDR/PIC, PSD, GIF, and
PNM/PPM/PGM images. Native compressed formats and other raylib-only formats use
their existing synchronous reload path. Fonts also retain synchronous reload.
These changes do not make scene loading, R3D model importing, or every asset
format asynchronous.

## Standalone managers and custom loops

An unconfigured manager retains its synchronous behavior. `assets.refresh`
remains an explicit synchronous operation: it drains and discards outstanding
texture requests, then loads changed textures/fonts before returning. Tools can
continue using it when a completed replacement is required immediately.

To use background replacements in a custom loop, borrow a pool explicitly:

```odin
assert(assets.configure_asset_jobs(&manager, pool))

// Every frame, before drawing with cached handles:
assets.pump_asset_jobs(&manager)
// At the desired file polling interval:
assets.refresh_background(&manager)
```

`configure_asset_jobs` accepts optional `Texture_Reload_Limits`. Start from
`assets.Default_Texture_Reload_Limits`; the defaults allow four requests, at
most 64 MiB of compressed input and 64 MiB of decoded output per request,
256 MiB of aggregate reserved input/output payload, two submissions per poll,
and one GPU upload attempt per frame. Each accepted request reserves its
snapshotted input length plus the complete decoded-output limit, so the byte
budget can admit fewer requests than the count limit. Reservations exclude
temporary native decoder scratch, allocator overhead, and GPU/driver storage;
they are not a total process-memory limit. File reads on workers cannot grow
beyond their snapshotted input reservation.

The manager owns stable request/group storage and native pixel results. The
pool remains caller-owned and must outlive those requests. Manager shutdown
waits for accepted jobs and frees their results before releasing cached GPU
resources. Detach with `assets.configure_asset_jobs(&manager, nil)` or shut down
the manager before destroying its pool. Reconfiguration also drains accepted
work and belongs outside a latency-sensitive update. The engine performs this
ordering for its owned manager and pool.

`assets.texture_reload_stats` reports current request/reservation counts and
completed/discarded installs for inspection. Normal asset memory estimates do
not include the native decoder's temporary scratch.

## 3D material replacements

Pass `worker_pool = game.worker_pool` to `r3d_bridge.init` to enable background
replacements of already-cached procedural materials and direct
albedo/normal/emission/ORM textures. First loads and a nil-pool renderer remain
synchronous. The same pool can serve the manager and renderer; each consumer
owns its requests and has its own upload limits.

Tools requiring immediate replacement can set
`Context.material_reload_synchronous = true` between draws while retaining the
pool for terrain/geometry. Background input uses regular files through
`core:os`; custom raylib file callbacks are not invoked on workers. Keep those
callback-dependent material replacements synchronous. Explicit `assets.refresh`
provides the corresponding synchronous manager operation.

Workers read bounded files through `rune:image_decode` and generate independent
procedural pixels. They never mutate the manager, renderer, or GPU. Old
materials remain installed while requests run or the queue is full. A request
must still match the current material fingerprint and all snapshotted source
timestamps before installation. Failed replacements retain the last working
material and are suppressed until another relevant change. The private decoder
supports more formats than some installed raylib builds; synchronous first-load
format support still follows the existing native loader.

Cached instance batches retry after admission failures and stale completions,
including when no material job was admitted. Terrain atlases follow successful
material installations, retaining their handles and pixels during pending or
failed replacements and across unrelated material edits.

`draw_scene_ex` automatically calls `r3d_bridge.pump_material_jobs` before
material submission. It freezes which completions are eligible and permits at
most one material replacement per draw. Direct custom material loops call that
pump before beginning native submission. This prevents a worker finishing
mid-submission from causing old GPU resources to be freed later in the same
draw. These are count budgets, not hard elapsed-time guarantees for a large
upload or shader compilation.

The renderer admits two requests, limits each input file to 64 MiB and each
request's prepared outputs/workspace reservation to 256 MiB. Compressed input
and native decoder scratch can add temporary memory beyond retained output;
these limits are not a total process-memory estimate. Unused completed results
are reclaimed after two unrequested pump boundaries. Keep the borrowed pool and
manager alive through bridge shutdown, which joins and frees every request.

Separate-channel generated ORM, full models, skyboxes, fonts, and other
unsupported containers keep their existing synchronous paths. Procedural color
upload now transfers an independent image copy to R3D instead of encoding and
decoding a temporary PNG. R3D consumes that copy; private decoder pixels are
always freed through their own native allocator.

`Context.frame_stats` includes `material_reload_started`,
`material_reload_completed`, `material_reload_discarded`,
`material_reload_deferred`, `material_reload_pending`, and
`material_reload_upload_cpu_ms`. The last field measures owner-thread
construction/installation elapsed time; worker preparation is asynchronous.

## Material cache ownership

Per-material fingerprints include authored/preview data and watched dependency
generations. Unrelated edits preserve existing maps and shaders. The aggregate
revision remains useful for rebuilding instance/batch metadata. Generated ORM
textures are manager-owned and renderer materials hold explicit leases;
affected retired entries stay alive until the final lease is released. Renderer
materials must be destroyed before their manager. Merely comparing the material
data signature would miss texture/shader file edits and is insufficient.
Cache hits also compare the source manager: equal path, fingerprint, and revision
values from different managers do not establish that the GPU resource is current.

## Validation

The `rune/assets/texture_reload_test.odin` headless test covers input/reservation
bounds, isolated decode failure, and retry suppression. Its optional
`assets.texture_background_reload_keeps_old_pixels_discards_stale_and_drains`
test uses `RUNE_TEXTURE_RELOAD_GPU_TESTS=true` and `ODIN_TEST_THREADS=1`; it
requires a graphics context and checks actual pixels, queue pressure, stale
results, missing-file recovery, upload limits, synchronous compatibility, and
shutdown. These checks passed with the pinned October Odin toolchain, MSVC,
static raylib 6, GLFW/Win32, and OpenGL 3.3 on an NVIDIA GTX 1060. They do not
establish Linux GPU behavior or a speedup for a particular game.

`tools/material_reload_validation --runtime` checks selective reuse, own-source
edits, shader failure retention, sampler variants, and generated ORM lifetime.
`tools/material_async_validation --runtime` checks queued/full pools, stale
previews, corrupt PNG/JPEG payload recovery, RGB/RGBA sRGB uploads, pump limits,
shutdown draining, serial compatibility, and actual cached prop/terrain draws.
It checks queue-full/stale retry progress and exact atlas retention through a
corrupt image edit and repair. Both passed on the same Windows
configuration. The private decoder and headless asset tests also passed on
Ubuntu 26.04.1 WSL2 with the pinned October Odin compiler. Linux GPU checks were
not run because an isolated Xvfb display was unavailable.
