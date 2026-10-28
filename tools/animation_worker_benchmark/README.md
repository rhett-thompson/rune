# Animation worker benchmark

This headless benchmark measures native R3D local-pose sampling, Rune's optional
TRS blend, and native model-pose hierarchy evaluation. It compares direct serial
evaluation with one or three background workers plus caller participation.
Pooled measurements include dispatch and the completion barrier. They call
`jobs.parallel_for` with the bridge's pose callback directly, deliberately
bypassing `evaluate_animation_poses`' production workload threshold so that small
batches can also be compared.

The synthetic fixture has 64 or 128 bones, a shared spine and dependent limb
chains, and 32 translation, quaternion-rotation, and scale keys per bone. Each
character has a different sample time, private animation state, and private
local/model output buffers. Skeletons and keyed channels are shared read-only.
Cases use 1, 2, 4, 8, 16, 32, 64, or 128 characters, with and without an outgoing
pose blend. The benchmark calls the checked-in native
`ComputeAnimationLocalPose` and `ComputeAnimationModelPose` implementations
through `r3d_bridge.evaluate_animation_pose`.

Each case runs three warmup rounds followed by fifteen measured rounds. Every
round rotates which method runs first, and every measured sample averages eight
complete batch evaluations. Results contain the median of those fifteen
samples, all raw samples, compiler/CPU metadata, and speedup relative to serial.
Character times and serial reference poses are updated outside the timed
interval. Every local and model matrix is checked for exact equality against
that round's serial reference after each method.

A separate untimed check submits two semaphore-gated jobs, verifies distinct
non-owner thread IDs and overlapping evaluation intervals, and checks their
poses against serial output. This establishes native CPU evaluation on actual
worker threads; caller participation alone would not establish that. A failed
correctness or worker-execution check gives a nonzero exit status.

No window, graphics context, model import, native animation-player creation,
skin texture, upload, or draw is used. Fixture allocation/destruction, timeline
advance, markers/callbacks, cache publication, and output validation are outside
the measured intervals. These are CPU-stage timings for one synthetic workload,
not whole-frame or game-performance measurements.

Build from Rune's root using the pinned compiler and optimized code. Windows:

```powershell
./tools/odin.ps1 -OdinArguments @('build', 'tools/animation_worker_benchmark', '-collection:rune=rune', '-collection:r3d=third_party/r3d-odin', '-linker:msvc', '-o:speed', '-out:build/animation_worker_benchmark.exe')
./build/animation_worker_benchmark.exe --out=build/animation-worker-benchmark-windows.json
```

Linux:

```sh
sh tools/odin.sh build tools/animation_worker_benchmark -collection:rune=rune -collection:r3d=third_party/r3d-odin -o:speed -out:build/animation_worker_benchmark
./build/animation_worker_benchmark --out=build/animation-worker-benchmark-linux.json
```

The tool rejects builds without `-o:speed`. Its only argument is an optional
`--out=report.json`; the default is `build/animation-worker-benchmark.json`.
Generated binaries and reports belong under ignored `build/`.

On 2026-10-28, Odin `dev-2026-10` / `84bc3fc`, `-o:speed`, and `x86-64-v2` on an
AMD Ryzen 7 3700X (8 cores, 16 logical processors) produced the following warmed
medians. Windows used Windows 11 build 26300 and MSVC linking. Linux was native
execution of a Linux binary under Ubuntu 26.04.1 / WSL2, rather than a cross-build
only. WSL scheduling is part of that observed Linux environment.

| Platform | Bones × characters | Blend | Serial ms | One worker ms | Three workers ms | Three-worker speedup |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| Windows | 64 × 32 | No | 0.26032 | 0.15685 | 0.10003 | 2.60× |
| Windows | 128 × 16 | No | 0.30551 | 0.16878 | 0.11384 | 2.68× |
| Windows | 64 × 32 | Yes | 0.48275 | 0.27974 | 0.16299 | 2.96× |
| Windows | 64 × 64 | Yes | 0.97119 | 0.51579 | 0.31029 | 3.13× |
| Linux / WSL2 | 64 × 32 | No | 0.17126 | 0.11032 | 0.11549 | 1.48× |
| Linux / WSL2 | 128 × 16 | No | 0.19138 | 0.15727 | 0.12975 | 1.47× |
| Linux / WSL2 | 64 × 32 | Yes | 0.65751 | 0.43260 | 0.29260 | 2.25× |
| Linux / WSL2 | 64 × 64 | Yes | 1.55603 | 0.86628 | 0.50128 | 3.10× |

Both runs passed exact pose equivalence in all 32 cases and the native worker
execution checks. Single-character cases were slower with dispatch on both
platforms. The 512-bone unblended cases sped up on Windows but regressed under
WSL2: three workers measured 0.62× for 64 × 8 and 0.59× for 128 × 4. The 2048-bone
cases above improved with either worker count on both platforms. These
observations support the current conservative common cutoff of 2048 total
bones and at least two players. Bone count is a heuristic: key density, blending,
CPU, operating system, pool contention, and other machine activity can change
the crossover. Re-run on the target game and hardware before relying on a
particular speedup.
