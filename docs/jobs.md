# CPU worker jobs

`rune:jobs` provides an optional fixed worker pool with a bounded FIFO queue.
Workers execute CPU callbacks using independent runtime contexts, persistent
heap allocation, and private temporary arenas. They do not inherit an engine
frame arena or the creating thread's allocator. Input, window/GPU calls, Clay,
asset-manager mutation, native World access, and component changes remain on
their owning thread.

Create a pool with `jobs.create(worker_count, queue_capacity=256)`. The count is
the number of additional threads, from 1 through 32; the queue accepts 1 through
4096 pending jobs. Creation returns `nil` for invalid settings or failure. A nil
pool selects serial execution in helpers that accept one. The pool has a stable
allocated address: retain the pointer, never copy its fields, and call
`jobs.destroy(pool)` from its owner when no other callers can still use it.
Destruction rejects new submissions, drains accepted work, joins every worker,
and frees the pool. It does not cancel accepted jobs.

For a synchronous batch, prefer:

```odin
import "rune:jobs"

compute_item :: proc(index: int, data: rawptr) {
    results := (^[]int)(data)
    results^[index] = index * index
}

pool := jobs.create(3, 64)
defer jobs.destroy(pool)
results := make([]int, 1000)
defer delete(results)
jobs.parallel_for(pool, len(results), compute_item, &results)
// All results are ready here.
```

`parallel_for` executes each index once and returns after every callback has
finished. The calling thread participates. Only a bounded number of runners
enter the pool; they share an atomic next-index counter. A nil/full pool falls
back to the caller, and nested batches called from a Rune worker execute inline
to avoid waiting for an exhausted pool. Callback completion order is unspecified;
use indexed, disjoint output slots and gather afterward when ordering matters.

After the caller exhausts the index range, the helper removes its own unused
queued runner tokens. A finished CPU batch therefore does not wait for those
tokens behind unrelated deferred work. It still joins runners already executing.
This internal cleanup preserves FIFO order and never removes, runs inline, or
cancels ordinary callbacks accepted through `jobs.submit`.

Each indexed callback receives separate temporary scratch whose lifetime ends
when that callback returns, including callbacks on the calling thread. Never
publish scratch pointers as results. Persistent `context.allocator` allocations
use the caller's allocator for inline callbacks and the runtime heap on workers.
Odin dynamic arrays retain their allocator; plain slices do not. Results stored
in plain slices must carry their allocation source, use an explicit allocator
safe across the participating threads, or be copied into owner storage after
the barrier and freed with their original allocator. Do not pass a frame,
tracking, or other unsynchronized allocator to workers.

For deferred work, use a zero-initialized `jobs.Group` at a stable address:

```odin
group: jobs.Group
if jobs.submit(pool, &group, do_work, &owned_input) {
    // Keep group, owned_input, and result storage alive and stable.
    jobs.wait(&group)
    // Or poll jobs.is_complete(&group) from the owner.
} else {
    do_work(&owned_input)
}
```

`do_work` has type `proc(data: rawptr)`. Submission is nonblocking and returns
false for a nil/full/stopping pool, nil group, or nil callback. Rejection changes
neither the group nor the data; the caller decides whether to retry or execute
inline. A Group counts only accepted jobs. Submit the full batch before waiting
or treating `is_complete` as its result. Completion synchronizes callback writes
with the observer. Reuse the same Group only after completion, with no concurrent
submissions or observers from its previous batch; never copy or zero a used
Group. A worker callback must not wait for work queued in the same pool. The
synchronous `parallel_for` helper handles nested batches itself.

Engine project configuration is optional:

```json
"jobs": { "worker_count": 3, "queue_capacity": 256 }
```

`worker_count` defaults to `0` (disabled). The engine owns its `worker_pool`;
use that pointer in supported consumers without destroying it yourself.
Standalone pools remain game-owned. Size CPU work to justify dispatch and
synchronization overhead; additional workers do not guarantee a speedup. Rune's
geometry chunk helper preserves serial output ordering with an optional pool;
see [static geometry](static-geometry.md). Physics workers have separate native
ownership and configuration described in [physics](physics.md).

The 3D bridge also uses its borrowed pool for independent skeletal pose
evaluation. It loads/reloads shared model and clip resources before gathering
jobs, then joins the local/blended/model pose batch before uploading skin
textures or publishing the evaluated player cache. Timelines, marker events,
imports, and player creation/destruction remain on the owner. Small batches and
saturated queues retain an inline path. See [skeletal animation](model-animation.md#cpu-pose-jobs)
for the supported native boundary and per-preparation statistics.

Particle simulation also borrows this pool. Engine-owned 2D updates gather
settings and emitter poses on the owner, reserve storage there, and join
independent emitter jobs before publishing State headers. Code-owned 3D bursts
opt in with the optional pool argument to `particles.update_3d`; disjoint range
integration joins before owner compaction. The 3D bridge uses its pool for large
billboard classification and per-batch compaction/sorting/stream packing, joining
before GPU upload. Retained arrays keep the owner allocator and are grown only
before dispatch. Rendering and World changes stay on the owner; enabling jobs
does not automatically advance code-owned 3D pools. See [particles](particles.md)
for borrowed-state lifetimes, statistics and scalar/GPU parity checks.

Focused `rune/jobs` tests cover queue saturation, repeated batch reuse,
drain/join shutdown, persistent output ownership, nested batches, and serial
fallback. Gated-worker regressions also check that caller-completed batches
return while unrelated callbacks remain blocked, preserving foreign jobs and
FIFO order across a wrapped queue. Run through `tools/odin.ps1` / `tools/odin.sh`
with the Rune collection and platform linker. Windows uses `-linker:msvc`; select
one test-runner thread when combining checks with graphics or shared UI context
tests.

`tools/jobs_validation --runtime` checks actual hidden engine startup with two
workers, draining an accepted callback during shutdown, and reinitialization
with the pool disabled. A graphics context is required; the default invocation
checks project settings and reports the skipped runtime branch. The aggregate
validators include scheduler tests and run the lifecycle check with `--runtime`.
