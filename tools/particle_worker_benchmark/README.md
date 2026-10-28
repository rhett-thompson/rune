# Particle worker benchmark

This headless tool compares original scalar particle simulation and billboard
preparation against Rune's worker helpers, using no pool, one additional worker,
or three additional workers. The caller participates in pooled batches. It
creates no window, graphics context, GPU buffer, texture, native model or import.
The linked 3D bridge is used only for its CPU billboard preparation functions.

Build from Rune's root with the pinned compiler and optimized code. Windows:

```powershell
./tools/odin.ps1 -OdinArguments @('build', 'tools/particle_worker_benchmark', '-collection:rune=rune', '-collection:r3d=third_party/r3d-odin', '-linker:msvc', '-o:speed', '-out:build/particle_worker_benchmark.exe')
./build/particle_worker_benchmark.exe --out=build/particle-worker-benchmark-windows.json
```

Linux:

```sh
sh tools/odin.sh build tools/particle_worker_benchmark -collection:rune=rune -collection:r3d=third_party/r3d-odin -o:speed -out:build/particle_worker_benchmark
./build/particle_worker_benchmark --out=build/particle-worker-benchmark-linux.json
```

The tool rejects builds without `-o:speed`. `--out=report.json` selects the report;
the default is `build/particle-worker-benchmark.json`. `--boundary` selects seven
smaller calibration cases instead of the complete 35-case matrix. `--large-3d`
selects three 3D cases at 131072, 262144 and 524288 particles. Choose one case
selection at a time; every selection still runs the three worker-execution
probes. Generated binaries, logs and JSON reports belong under ignored `build/`.

## Work and correctness

The default matrix includes:

- 2D simulation: one through 128 independent emitters, from 256 through 131072
  total live particles. The seeded fixture includes deaths, swap/pop removal,
  continuous births, gravity and fractional emission credit.
- 3D simulation: a single slice of 2048 through 131072 particles emitted from a
  deterministic burst, including deaths and motion. The scalar baseline retains
  the original single-pass age/death/swap loop. Pooled work uses disjoint
  1024-particle integration ranges, followed by owner-side ordered swap/pop
  compaction.
- Billboard preparation: 2048 through 131072 source particles, in one or eight
  batches, for both additive and alpha blending. Inputs include invisible and
  invalid-lifetime particles, repeated depth keys, varied positions and camera
  changes. Filtering, ordered compaction, alpha sorting and position/scale/color
  stream packing are included.

Fixtures are reset and scalar references computed outside the timed interval.
2D comparisons include every live particle, its order, random state and emission
credit. 3D comparisons include the complete returned live prefix in its original
swap/pop order; storage beyond that prefix is unspecified. Billboard comparisons
include instances, depth, positions, scales and colors, and verify that the input
particles remain unchanged. Every measured method must match its reference
exactly.

Separate untimed, semaphore-gated probes execute each stage on two distinct
non-owner OS threads. They check overlapping work intervals and exact results.
These checks establish actual background execution rather than merely selecting
the parallel path while the caller handles every index. Any correctness or
worker-execution failure produces a nonzero exit status.

## Timing boundary

Each case uses three warmup rounds and fifteen measured rounds, rotating which
method runs first. Samples average four complete updates/preparations; alpha
cases with at least 32768 inputs use one preparation because the sort already
provides a long interval. Each result records its iteration count. Reports contain
all samples, mean, median, nearest-rank p95, maximum, median speedup, compiler/CPU
metadata, and the production thresholds present when built. With fifteen samples,
nearest-rank p95 equals the maximum; it is a small-sample statistic.

The benchmark deliberately bypasses pooled dispatch thresholds to reveal smaller
workloads that regress. 2D pooled timing includes owner-side `prepare_update`,
then the production prepared-emitter callback. 3D timing includes range dispatch,
both integration and the owner compaction. Billboard timing includes warmed
storage/descriptor setup, classification, ordered compaction, sorting, stream
packing and the applicable barriers. A single alpha batch still sorts on the
caller; separate batches can finalize and sort independently. First allocations,
fixture reset, reference calculation and validation are excluded.

The tool does not measure ECS gather/commit, hierarchy traversal, material lookup,
GPU upload/draw, or whole-frame performance. Timings describe these seeded CPU
fixtures, not an arbitrary game. Dispatch, allocator/runtime setup, cache traffic,
worker count and OS scheduling can dominate cheap particle integration.

## Observed results

On 2026-10-28, pinned Odin `84bc3fc`, `-o:speed`, and `x86-64-v2` ran on an AMD
Ryzen 7 3700X with 8 cores and 16 logical processors. Windows used build 26300 and
MSVC linking. Linux was native Linux binary execution under Ubuntu 26.04.1/WSL2,
including WSL's scheduling overhead. Windows and Linux runs were sequential.
Both complete runs passed all 35 cases and all three worker-execution probes.

The table gives warmed median milliseconds per update/preparation. Worker counts
are additional background threads; speedup compares three workers with scalar.

| Platform | Stage and fixture | Scalar ms | One worker ms | Three workers ms | Speedup |
| --- | --- | ---: | ---: | ---: | ---: |
| Windows | 2D, 128 emitters × 1024 particles | 0.33265 | 0.17690 | 0.10505 | 3.17× |
| Linux / WSL2 | 2D, 128 emitters × 1024 particles | 0.28975 | 0.20871 | 0.23249 | 1.25× |
| Windows | 3D, one slice × 131072 particles | 0.35537 | 0.31548 | 0.22985 | 1.55× |
| Linux / WSL2 | 3D, one slice × 131072 particles | 0.38535 | 0.42159 | 0.43919 | 0.88× |
| Windows | Additive billboards, one batch × 16384 | 0.32635 | 0.24490 | 0.16775 | 1.95× |
| Linux / WSL2 | Additive billboards, one batch × 16384 | 0.31088 | 0.28388 | 0.26361 | 1.18× |
| Windows | Alpha billboards, one batch × 131072 | 43.19120 | 43.01770 | 42.65660 | 1.01× |
| Linux / WSL2 | Alpha billboards, one batch × 131072 | 47.40404 | 46.91457 | 47.00498 | 1.01× |
| Windows | Alpha billboards, eight batches × 16384 | 34.71020 | 22.44240 | 11.69590 | 2.97× |
| Linux / WSL2 | Alpha billboards, eight batches × 16384 | 37.02443 | 19.79728 | 10.49493 | 3.53× |

Small forced-dispatch cases often regress. In the final WSL run, three workers
measured 0.63× for 32768 live 2D particles, 0.66× for 65536 live 3D particles,
and 0.86× for one additive billboard batch of 8192 inputs. The billboard 16384
gate avoids that smaller measured preparation regression. Simulation gates use
131072 estimated live-plus-birth work for 2D and live particles for 3D. These are
heuristics, not universal crossover points: repeated WSL runs moved the 131072
3D result from a modest gain to a regression.

The separate `--large-3d` investigation also passed all exact comparisons and
worker probes on both platforms, but larger slices did not establish a stable
crossover. The repeated 131072 case measured 1.17× with three workers on Windows
and 1.06× under WSL2, compared with 1.55× and 0.88× in the complete runs above.

| Platform | 3D live particles | Scalar ms | One worker ms | Three workers ms | Three-worker speedup |
| --- | ---: | ---: | ---: | ---: | ---: |
| Windows | 262144 | 1.60553 | 1.98010 | 1.69738 | 0.95× |
| Windows | 524288 | 2.46060 | 2.99792 | 2.83575 | 0.87× |
| Linux / WSL2 | 262144 | 0.93564 | 1.11025 | 0.92610 | 1.01× |
| Linux / WSL2 | 524288 | 2.44787 | 3.25169 | 3.01779 | 0.81× |

The 3D worker path is an explicit opt-in by passing a pool; omitting it retains
the original scalar algorithm. Its extra integration/compaction pass introduces
memory traffic, and observed results are consistent with dispatch/cache/memory
costs limiting this cheap kernel. These measurements do not isolate those causes.
Increasing the count or number of workers does not guarantee an improvement.
Re-run on the target game and machine; these measurements do not establish
ordinary desktop-Linux behavior or GPU performance.
