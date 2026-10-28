# Box3D worker benchmark

This standalone CPU fixture compares Rune's `ecs.physics_3d_update` with 1, 2,
4, and 8 Box3D workers. It creates 512 dynamic boxes in an 8×8×8 arrangement
above a floor, enclosed by four walls. Native sleeping is disabled so the
measurement continues solving active contacts after warmup. No window, renderer,
audio device, frame cap, or general Rune worker pool is involved.

From the repository root on Windows:

```powershell
./tools/odin.ps1 -OdinArguments @('build','tools/physics_worker_benchmark','-collection:rune=rune','-collection:r3d=third_party/r3d-odin','-linker:msvc','-o:speed','-out:build/physics_worker_benchmark.exe')
./build/physics_worker_benchmark.exe
```

On Linux:

```sh
sh tools/odin.sh build tools/physics_worker_benchmark -collection:rune=rune -collection:r3d=third_party/r3d-odin -o:speed -out:build/physics_worker_benchmark
./build/physics_worker_benchmark
```

The executable rejects builds below `-o:speed`. The default run uses 120 warmup
steps followed by 360 measured steps per trial, with three fresh trials per
worker count. Each step advances exactly 1/60 second. The first worker count
rotates between trials to reduce consistent ordering bias. Each fresh scene
installs one body at a time so native insertion order is stable across World's
generation-bound entity IDs and hash-map iteration order.

Optional arguments are `--warmup=60..3600`, `--steps=120..3600`,
`--trials=3..20`, and `--out=path.json`. Keep output in `build/`; the default is
`build/physics-worker-benchmark.json`. A custom output parent must exist or be
creatable as one directory. Reusing a path replaces its previous report.

Setup, warmup, scratch reset, statistics, correctness checks, and teardown are
outside the timed region. Each sample covers native-body synchronization,
Box3D stepping/worker joins, event collection, and pose synchronization through
Rune's normal physics update. Reports include raw step samples, each trial's
mean/p95/max, pooled step statistics, trial-mean statistics, compiler/optimization
metadata, and the platform. `cpu_description` uses Windows' processor environment
description when available; record the CPU model separately on other systems.
No affinity, power policy, thermal state, or desktop workload is controlled.

Every trial verifies the requested native worker count, 517 native bodies and
shapes, active contacts, finite velocities/poses, bounded positions, and final
positions within 0.01 scene units of the first serial trial. Failed correctness
checks remain in the JSON report and produce a nonzero exit status. This fixture
does not establish visual behavior, another CPU/backend, or whole-game speedup.

## Recorded validation

On 2026-10-28, the pinned Odin `dev-2026-10-nightly:84bc3fc`, MSVC, `-o:speed`,
and `x86-64-v2` target ran the default fixture on Windows AMD64 with an AMD Ryzen
7 3700X (8 physical cores, 16 logical processors). All 12 trials passed the
correctness checks, with zero recorded final-position delta. Pooled results from
1,080 measured steps per worker count were:

| Workers, including caller | Mean ms | p95 ms | Maximum ms |
| --- | --- | --- | --- |
| 1 | 0.8894 | 1.0642 | 1.7263 |
| 2 | 0.7083 | 0.8877 | 1.5690 |
| 4 | 0.5567 | 0.7788 | 1.6979 |
| 8 | 0.5598 | 0.7012 | 1.1950 |

These measurements support trying four workers for this active-contact workload;
eight did not improve its mean. They do not change Rune's default of one physics
worker or establish a benefit for the general job pool. Linux runtime and other
CPU families remain unmeasured. Compare repeated optimized runs of a game's
representative scene before selecting its project setting.
