# ECS expiry and character-trigger benchmark

This headless CPU fixture measures `ecs.update_lifetimes` when independent roots
expire together and `ecs.update_triggers_3d` with spatially disjoint character
capsules. No window, renderer, audio, worker pool, or frame cap is involved.

From Rune's root on Windows:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
./tools/odin.ps1 -OdinArguments @('build','tools/ecs_performance_benchmark','-collection:rune=rune','-linker:msvc','-o:speed','-out:build/ecs_performance_benchmark.exe')
./build/ecs_performance_benchmark.exe | Tee-Object -FilePath build/ecs-performance-benchmark.txt
```

On Linux:

```sh
mkdir -p build
sh tools/odin.sh build tools/ecs_performance_benchmark -collection:rune=rune -o:speed -out:build/ecs_performance_benchmark
./build/ecs_performance_benchmark > build/ecs-performance-benchmark.txt
```

The executable rejects builds below `-o:speed` and prints compiler, target and
optimization metadata. Keep binaries and reports under ignored `build/`.

Each expiry fixture uses three fresh Worlds. Setup, the initial hierarchy build,
a non-expiring update, assertions, and teardown are outside the measured expiry
interval. All expiring roots have `Lifetime{seconds=1}`; the control advances
0.01 seconds and the timed update advances one second. Persistent entities have
no components. Output contains every sample, its non-expiring control, hierarchy
rebuild count during expiry, and the median of three samples. Assertions verify
the exact remaining entity count. Fixtures cover 250, 500, 1000 and 2000 expiring
roots alone, 250 beside 5000 persistent roots, and 1000 beside 10000.

Trigger fixtures put two-unit boxes four units apart along X at Z=0. Root-space
default character capsules are also four units apart but at Z=10000. All share
the Default layer; no pair overlaps. Three warmups precede nine measured ticks;
output gives median and maximum tick time. Timing includes capsule gathering,
spatial-tree preparation, native empty-world queries and event processing. Every
tick asserts zero events. This measures pruning of distant characters, rather
than dense overlapping contacts. Exact hit/event parity, tilted/crouched capsules,
movement, activation and native destruction are covered by serial `rune/ecs`
tests in `triggers_3d_test.odin` and `entity_destruction_test.odin`.

The fixtures do not control affinity, power policy, temperature or other desktop
work. They do not establish whole-game frame rate, GPU behavior, another CPU, or
Linux performance. Dense overlapping trigger/actor populations still require
their actual pair tests and events.

## Recorded Windows comparison

On 2026-10-31, pinned Odin `84bc3fc`, MSVC, `-o:speed` and `x86-64-v2` ran
these same fixtures on Windows AMD64 with a Ryzen 9 5900X (12 cores, 24 logical
processors). Before/after medians in milliseconds were:

| Fixture | Before | After |
| --- | ---: | ---: |
| 1000 expirations beside 10000 persistent roots | 51.4078 | 0.5809 |
| 2000 expirations, no persistent roots | 12.5129 | 1.2015 |
| 500 triggers, 500 disjoint characters | 16.0995 | 0.1266 |
| 1000 triggers, 1000 disjoint characters | 77.5230 | 0.2830 |

The expiry change eliminated the 999/1999 intervening hierarchy rebuilds in the
two recorded cases. Trigger preparation now builds a current capsule-bounds tree
once, then prunes distant nodes before exact tests. These are isolated fixture
measurements with the sampling and environment limits described above.
