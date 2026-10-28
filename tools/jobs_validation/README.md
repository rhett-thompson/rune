# Engine job-pool lifecycle validation

Build from Rune's repository root on Windows:

```powershell
./tools/odin.ps1 -OdinArguments @('build','tools/jobs_validation','-collection:rune=rune','-collection:r3d=third_party/r3d-odin','-linker:msvc','-out:build/jobs_validation.exe')
./build/jobs_validation.exe --runtime
```

On Linux use `sh tools/odin.sh build` with the same collections, omit the MSVC
linker flag, and choose an executable output without `.exe`.

The default run checks project decoding and explicitly skips graphics runtime.
`--runtime` initializes an actual hidden Rune window on the process main thread
with two additional job workers and queue capacity one, submits a delayed callback,
and shuts down immediately. It verifies that shutdown drains the callback and
clears the owned pool, then initializes another engine with jobs omitted and
verifies its pool remains nil. Fixture files live under ignored `build/` and are
removed on successful completion. A working display/OpenGL backend is required.

The package's headless tests cover decoding and scene propagation;
`rune/jobs` tests cover queueing, completion, and pool ownership. This standalone
tool separately exercises real window initialization and teardown.

On 2026-10-28, the pinned October Odin compiler with MSVC on Windows AMD64
reproduced native status `0xC00000FD` (stack overflow) during `InitWindow` in
both a guarded core test and this standalone tool. The enlarged 600-frame
profiling array occupied 52,800 bytes inline in every Engine value and its
temporary copies. Allocating only the requested profile samples on demand,
then releasing them on completion/interruption/shutdown, resolved the
unoptimized standalone failure with the same 1 MiB executable stack reserve.
The two-engine hidden lifecycle passed on GLFW/Win32, OpenGL 3.3, and an NVIDIA
GTX 1060; all 44 serial core tests passed with memory tracking. These checks do
not establish Linux runtime behavior. Keep large diagnostic buffers out of
value-returned engine state; see `rune/core/debug_commands.odin` and
`rune/core/profile_timings.odin` for sample ownership.
