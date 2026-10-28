// Bounded CPU jobs. Callbacks own their writes; this package does not schedule
// World, graphics, input, or UI access.
package jobs

import "base:runtime"
import "core:mem"
import "core:sync"
import "core:thread"

Max_Workers :: 32
Max_Queue_Capacity :: 4096
Default_Queue_Capacity :: 256

Job_Proc :: #type proc(data: rawptr)
Indexed_Proc :: #type proc(index: int, data: rawptr)

// Zero-initialize at its final address. Never copy a used Group. Submit the
// complete batch before waiting/polling; reuse this same Group after completion.
// Its address and every submitted data pointer must remain valid until then.
Group :: struct {
	mutex: sync.Mutex,
	completed: sync.Cond,
	pending: int,
}

@(private)
Job :: struct {procedure: Job_Proc, data: rawptr, group: ^Group}

// Only create/destroy own Pool storage. Do not copy it or access its fields.
// Destruction requires exclusive ownership: no concurrent callers may retain or
// submit through the pointer. Accepted callbacks are drained before it is freed.
Pool :: struct {
	mutex: sync.Mutex,
	available: sync.Cond,
	queue: []Job,
	head, count: int,
	stopping: bool,
	workers: []^thread.Thread,
	allocator: mem.Allocator,
}

@(thread_local, private)
worker_thread: bool

// worker_count counts additional threads, excluding the caller. A disabled pool
// is nil; creation accepts 1..Max_Workers and 1..Max_Queue_Capacity queued jobs.
// Pool metadata uses allocator only on its owning thread. Workers use their own
// fresh runtime context, heap allocations, and private temporary arenas.
create :: proc(worker_count: int, queue_capacity: int = Default_Queue_Capacity, allocator := context.allocator) -> ^Pool {
	if worker_count < 1 || worker_count > Max_Workers || queue_capacity < 1 || queue_capacity > Max_Queue_Capacity {return nil}
	pool,err:=mem.new(Pool,allocator)
	if err!=nil {return nil}
	pool.allocator=allocator
	pool.queue,err=make([]Job,queue_capacity,allocator)
	if err!=nil {destroy(pool);return nil}
	pool.workers,err=make([]^thread.Thread,worker_count,allocator)
	if err!=nil {destroy(pool);return nil}
	for &worker in pool.workers {
		worker=create_worker(pool)
		if worker==nil {destroy(pool);return nil}
	}
	return pool
}

// Stop accepting work, drain accepted jobs, join every worker, then release the
// pool. Call on the owner thread after other pool users have returned.
destroy :: proc(pool: ^Pool) {
	if pool==nil {return}
	sync.mutex_lock(&pool.mutex)
	pool.stopping=true
	sync.cond_broadcast(&pool.available)
	sync.mutex_unlock(&pool.mutex)
	for worker in pool.workers {if worker!=nil {thread.destroy(worker)}}
	a:=pool.allocator
	delete(pool.queue,a);delete(pool.workers,a);mem.free(pool,a)
}

// Nonblocking submission. A full/stopping/nil pool rejects the job without
// changing group or data; callers can execute it inline or retry later. Callbacks
// may submit jobs, but must not block waiting on jobs in the same pool.
submit :: proc(pool: ^Pool, group: ^Group, procedure: Job_Proc, data: rawptr) -> bool {
	if pool==nil || group==nil || procedure==nil {return false}
	sync.mutex_lock(&pool.mutex)
	defer sync.mutex_unlock(&pool.mutex)
	if pool.stopping || pool.count==len(pool.queue) {return false}
	sync.mutex_lock(&group.mutex)
	group.pending+=1
	sync.mutex_unlock(&group.mutex)
	pool.queue[(pool.head+pool.count)%len(pool.queue)]={procedure,data,group}
	pool.count+=1
	sync.cond_signal(&pool.available)
	return true
}

// Completion synchronizes callback writes with the observing thread. Do not
// start adding a new batch concurrently with a wait or completion observation.
wait :: proc(group: ^Group) {
	if group==nil {return}
	sync.mutex_lock(&group.mutex)
	for group.pending>0 {sync.cond_wait(&group.completed,&group.mutex)}
	sync.mutex_unlock(&group.mutex)
}

is_complete :: proc(group: ^Group) -> bool {
	if group==nil {return true}
	sync.mutex_lock(&group.mutex)
	complete:=group.pending==0
	sync.mutex_unlock(&group.mutex)
	return complete
}

@(private)
create_worker :: proc(pool: ^Pool) -> ^thread.Thread {
	// Thread handle creation/destruction must not retain the creator's frame or
	// tracking allocator. No init_context is supplied: Odin initializes a fresh one.
	context.allocator=runtime.default_context().allocator
	worker:=thread.create(worker_main)
	if worker!=nil {worker.data=pool;thread.start(worker)}
	return worker
}

@(private)
worker_main :: proc(worker: ^thread.Thread) {
	pool:=(^Pool)(worker.data)
	worker_thread=true
	context.allocator=runtime.default_context().allocator
	arena:mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena,block_allocator=runtime.default_context().allocator,array_allocator=runtime.default_context().allocator)
	defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator=mem.dynamic_arena_allocator(&arena)
	for {
		sync.mutex_lock(&pool.mutex)
		for pool.count==0 && !pool.stopping {sync.cond_wait(&pool.available,&pool.mutex)}
		if pool.count==0 && pool.stopping {sync.mutex_unlock(&pool.mutex);break}
		job:=pool.queue[pool.head]
		pool.queue[pool.head]={}
		pool.head=(pool.head+1)%len(pool.queue);pool.count-=1
		sync.mutex_unlock(&pool.mutex)
		job.procedure(job.data)
		free_all(context.temp_allocator)
		sync.mutex_lock(&job.group.mutex)
		job.group.pending-=1
		if job.group.pending==0 {sync.cond_broadcast(&job.group.completed)}
		sync.mutex_unlock(&job.group.mutex)
	}
}

@(private)
Parallel_Batch :: struct {procedure: Indexed_Proc, data: rawptr, count, next: int}

// Execute each index exactly once and wait for all callbacks. The caller helps;
// nil/full pools and nested worker calls retain a synchronous inline path.
// Immutable input and disjoint output storage must remain alive until return.
// Per-index scratch is reset after the callback; retained outputs need persistent
// allocations. Explicit allocators shared with workers must be thread-safe.
parallel_for :: proc(pool: ^Pool, count: int, procedure: Indexed_Proc, data: rawptr) {
	if count<=0 || procedure==nil {return}
	batch:=Parallel_Batch{procedure=procedure,data=data,count=count}
	group:Group
	if pool!=nil && !worker_thread {
		for _ in 0..<min(count,len(pool.workers)) {submit(pool,&group,parallel_run,&batch)}
	}
	parallel_run(&batch)
	// The caller has exhausted the index range. Queued runners cannot contribute
	// work now, and need not wait behind unrelated deferred callbacks. Running
	// runners still own the batch until wait returns; ordinary jobs are untouched.
	if pool!=nil && !worker_thread && !is_complete(&group) {prune_parallel_runners(pool,&group,&batch)}
	wait(&group)
}

@(private)
prune_parallel_runners :: proc(pool:^Pool,group:^Group,batch:^Parallel_Batch) {
	sync.mutex_lock(&pool.mutex)
	defer sync.mutex_unlock(&pool.mutex)
	kept:=0
	removed:=0
	queued:=pool.count
	for offset in 0..<queued {
		job:=pool.queue[(pool.head+offset)%len(pool.queue)]
		if job.group==group && job.procedure==parallel_run && job.data==batch {
			removed+=1
			continue
		}
		pool.queue[(pool.head+kept)%len(pool.queue)]=job
		kept+=1
	}
	for offset in kept..<queued {pool.queue[(pool.head+offset)%len(pool.queue)]={}}
	pool.count=kept
	if removed>0 {
		// Match submit's pool->group lock order. A popped/running runner is not
		// removed here and must finish before this private stack Group can expire.
		sync.mutex_lock(&group.mutex)
		group.pending-=removed
		if group.pending==0 {sync.cond_broadcast(&group.completed)}
		sync.mutex_unlock(&group.mutex)
	}
}

@(private)
parallel_run :: proc(data: rawptr) {
	batch:=(^Parallel_Batch)(data)
	// Own a nested arena even on the caller, leaving its frame/outer-job scratch
	// alive. Each indexed callback gets bounded scratch lifetime.
	arena:mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena,block_allocator=runtime.default_context().allocator,array_allocator=runtime.default_context().allocator)
	defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator=mem.dynamic_arena_allocator(&arena)
	for {
		index:=sync.atomic_add(&batch.next,1)
		if index>=batch.count {break}
		batch.procedure(index,batch.data)
		free_all(context.temp_allocator)
	}
}
