# Geometry worker benchmark

This focused CPU benchmark creates a 96 × 64 × 96 solid voxel volume, carves
64 rooms, and extracts 144 logical 16³ chunks. It compares the default serial
`geometry.surface_chunks` call against three background workers plus caller
participation, using a 64-slot queue. Both paths execute once for warmup, then
nine measured pairs; each pair runs serial first. The tool reports each path's
median and their ratio. Chunk output equivalence is tested separately in
`rune/geometry/chunks_test.odin`.

Setup, result destruction, World installation, collision construction, GPU
upload, and rendering are outside the measured intervals. This is one geometry
workload; timing depends on the CPU, allocator, compiler settings, and other
machine activity. It does not measure whole-frame improvement or promise a
speedup for different games.

Build from Rune's root with the pinned compiler and optimized code. Windows:

```powershell
./tools/odin.ps1 -OdinArguments @('build', 'tools/geometry_worker_benchmark', '-collection:rune=rune', '-linker:msvc', '-o:speed', '-out:build/geometry_worker_benchmark.exe')
./build/geometry_worker_benchmark.exe
```

Linux:

```sh
sh tools/odin.sh build tools/geometry_worker_benchmark -collection:rune=rune -o:speed -out:build/geometry_worker_benchmark
./build/geometry_worker_benchmark
```

The tool is headless and needs no graphics context or external assets. Redirect
stdout into an ignored `build/` report if recording a comparison.

On 2026-10-28, the pinned Odin October toolchain, MSVC, and `-o:speed` on Windows
AMD64 with an AMD Ryzen 7 3700X measured 11.864 ms serial and 6.497 ms with three
workers plus caller participation (median of nine warmed pairs, 1.83×). This
records the CPU extraction fixture above; it does not establish terrain,
pathfinding, frame-rate, Linux, or other hardware performance.
