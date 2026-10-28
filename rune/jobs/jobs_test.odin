package jobs

import "base:runtime"
import "core:mem"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(private)
Blocked_Job :: struct {started, release: sync.Sema, writes: int}

@(private)
blocked_job :: proc(data: rawptr) {
	job:=(^Blocked_Job)(data)
	scratch:=make([]u8,8192,context.temp_allocator)
	for &v in scratch {v=173}
	sync.sema_post(&job.started)
	sync.sema_wait(&job.release)
	for v in scratch {assert(v==173,"worker scratch survives while another thread uses its own scratch")}
	job.writes+=1
}

@(private)
increment_job :: proc(data: rawptr) {(^int)(data)^+=1}

@(test)
bounded_queue_rejects_without_adding_to_group_and_reuses_batches :: proc(t:^testing.T) {
	pool:=create(1,1)
	if !testing.expect(t,pool!=nil) {return}
	defer destroy(pool)
	group:Group;block:Blocked_Job;queued_writes:int
	testing.expect(t,submit(pool,&group,blocked_job,&block))
	started:=sync.sema_wait_with_timeout(&block.started,2*time.Second)
	if !testing.expect(t,started,"a worker starts the blocking fixture") {sync.sema_post(&block.release);wait(&group);return}
	testing.expect(t,submit(pool,&group,increment_job,&queued_writes),"one queue slot remains behind the running job")
	testing.expect(t,!submit(pool,&group,increment_job,&queued_writes),"a full queue rejects instead of growing")
	testing.expect(t,!is_complete(&group))
	caller_scratch:=make([]u8,8192,context.temp_allocator)
	for &v in caller_scratch {v=61}
	sync.sema_post(&block.release)
	wait(&group)
	testing.expect(t,is_complete(&group) && block.writes==1 && queued_writes==1,"rejection leaves no phantom pending work")
	for v in caller_scratch {testing.expect(t,v==61,"worker scratch never shares the caller's arena")}
	for _ in 0..<8 {
		testing.expect(t,submit(pool,&group,increment_job,&queued_writes))
		wait(&group)
	}
	testing.expect(t,queued_writes==9,"a completed Group can track another batch at the same address")
}

@(test)
shutdown_drains_accepted_work_and_joins_workers :: proc(t:^testing.T) {
	pool:=create(1,3)
	if !testing.expect(t,pool!=nil) {return}
	group:Group;block:Blocked_Job;writes:[3]int
	if !testing.expect(t,submit(pool,&group,blocked_job,&block)) {destroy(pool);return}
	started:=sync.sema_wait_with_timeout(&block.started,2*time.Second)
	if !testing.expect(t,started) {sync.sema_post(&block.release);destroy(pool);return}
	for &value in writes {testing.expect(t,submit(pool,&group,increment_job,&value))}
	sync.sema_post(&block.release)
	destroy(pool)
	testing.expect(t,is_complete(&group) && block.writes==1 && writes==[3]int{1,1,1},"destroy drains every accepted job before freeing the pool")
}

@(private)
Indexed_Result :: struct {writes:int, bytes:[]u8, allocator:mem.Allocator, scratch:rawptr}

@(private)
indexed_result_job :: proc(index:int,data:rawptr) {
	results:=(^[]Indexed_Result)(data)
	result:=&results^[index]
	result.writes+=1
	result.allocator=context.allocator
	result.bytes=make([]u8,31)
	result.scratch=context.temp_allocator.data
	scratch:=make([]u8,16384,context.temp_allocator)
	for &value in scratch {value=u8(index%251)}
	for &value in result.bytes {value=scratch[0]}
}

@(test)
parallel_batches_preserve_owned_outputs_and_execute_every_index_once :: proc(t:^testing.T) {
	pool:=create(3,1)
	if !testing.expect(t,pool!=nil) {return}
	defer destroy(pool)
	for _ in 0..<12 {
		results:=make([]Indexed_Result,73)
		parallel_for(pool,len(results),indexed_result_job,&results)
		for result,index in results {
			testing.expect(t,result.writes==1 && len(result.bytes)==31)
			testing.expect(t,result.scratch!=context.temp_allocator.data,"indexed callbacks get independent nested scratch")
			for value in result.bytes {testing.expect(t,value==u8(index%251),"owned results outlive worker scratch resets")}
			delete(result.bytes,result.allocator)
		}
		delete(results)
	}
}

@(private)
Nested_Batch :: struct {pool:^Pool, values:[16][7]int}

@(private)
nested_outer :: proc(index:int,data:rawptr) {
	batch:=(^Nested_Batch)(data)
	values:=batch.values[index][:]
	parallel_for(batch.pool,len(values),proc(i:int,p:rawptr) {(^[]int)(p)^[i]+=1},&values)
}

@(test)
nested_and_nil_pool_batches_complete_without_starvation :: proc(t:^testing.T) {
	pool:=create(2,1)
	if !testing.expect(t,pool!=nil) {return}
	defer destroy(pool)
	batch:=Nested_Batch{pool=pool}
	parallel_for(pool,len(batch.values),nested_outer,&batch)
	for values in batch.values {for value in values {testing.expect(t,value==1)}}
	batch.pool=nil
	parallel_for(nil,len(batch.values),nested_outer,&batch)
	for values in batch.values {for value in values {testing.expect(t,value==2)}}
	testing.expect(t,create(0)==nil && create(Max_Workers+1)==nil && create(1,0)==nil && create(1,Max_Queue_Capacity+1)==nil)
	testing.expect(t,!submit(nil,nil,nil,nil) && is_complete(nil))
	// Persistent allocations in the worker use the runtime heap, which is safe
	// to release explicitly from a different thread.
	testing.expect(t,runtime.default_context().allocator.procedure!=nil)
}

@(private)
Batch_Watchdog :: struct {
	finished: sync.Sema,
	blocks: []Blocked_Job,
	expired: bool,
}

@(private)
batch_watchdog :: proc(watch_thread:^thread.Thread) {
	watch:=(^Batch_Watchdog)(watch_thread.data)
	if !sync.sema_wait_with_timeout(&watch.finished,2*time.Second) {
		watch.expired=true
		for &block in watch.blocks {sync.sema_post(&block.release)}
	}
}

@(private)
start_batch_watchdog :: proc(watch:^Batch_Watchdog) -> ^thread.Thread {
	context.allocator=runtime.default_context().allocator
	watch_thread:=thread.create(batch_watchdog)
	if watch_thread!=nil {watch_thread.data=watch;thread.start(watch_thread)}
	return watch_thread
}

@(test)
parallel_batch_drops_unused_runners_behind_occupied_workers :: proc(t:^testing.T) {
	pool:=create(2,8)
	if !testing.expect(t,pool!=nil) {return}
	defer destroy(pool)
	group:Group
	blocks:[2]Blocked_Job
	for &block in blocks {testing.expect(t,submit(pool,&group,blocked_job,&block))}
	defer {for &block in blocks {sync.sema_post(&block.release)};wait(&group)}
	for &block in blocks {
		if !testing.expect(t,sync.sema_wait_with_timeout(&block.started,2*time.Second)) {return}
	}
	watch:=Batch_Watchdog{blocks=blocks[:]}
	watch_thread:=start_batch_watchdog(&watch)
	if !testing.expect(t,watch_thread!=nil) {return}
	values:[17]int
	parallel_for(pool,len(values),proc(index:int,data:rawptr) {(^[17]int)(data)^[index]+=1},&values)
	sync.sema_post(&watch.finished)
	thread.destroy(watch_thread)
	testing.expect(t,!watch.expired,"caller-completed batches do not wait for occupied workers when the queue has room")
	for value in values {testing.expect(t,value==1,"every index executes once before return")}
	testing.expect(t,!is_complete(&group),"the batch returns while unrelated worker callbacks remain blocked")
	sync.mutex_lock(&pool.mutex)
	queued:=pool.count
	sync.mutex_unlock(&pool.mutex)
	testing.expect(t,queued==0,"unused private runners leave no queued stack references")
}

@(private)
Ordered_Jobs :: struct {values:[2]int, on_worker:[2]bool, count:int}
@(private)
Ordered_Job :: struct {state:^Ordered_Jobs,value:int}

@(private)
ordered_job :: proc(data:rawptr) {
	job:=(^Ordered_Job)(data)
	index:=job.state.count
	job.state.values[index]=job.value
	job.state.on_worker[index]=worker_thread
	job.state.count+=1
}

@(private)
Mixed_Batch :: struct {pool:^Pool,group:^Group,queued:^Ordered_Job,submitted:bool,values:[7]int}

@(private)
mixed_batch_item :: proc(index:int,data:rawptr) {
	batch:=(^Mixed_Batch)(data)
	batch.values[index]+=1
	if index==0 {batch.submitted=submit(batch.pool,batch.group,ordered_job,batch.queued)}
}

@(test)
parallel_runner_pruning_preserves_foreign_jobs_and_fifo_across_ring_wrap :: proc(t:^testing.T) {
	pool:=create(1,4)
	if !testing.expect(t,pool!=nil) {return}
	defer destroy(pool)
	group:Group
	// Advance the ring head so the mixed queue below spans its physical end.
	warmup:int
	if !testing.expect(t,submit(pool,&group,increment_job,&warmup)) {return}
	wait(&group)
	blocks:[1]Blocked_Job
	if !testing.expect(t,submit(pool,&group,blocked_job,&blocks[0])) {return}
	defer {sync.sema_post(&blocks[0].release);wait(&group)}
	if !testing.expect(t,sync.sema_wait_with_timeout(&blocks[0].started,2*time.Second)) {return}
	ordered:Ordered_Jobs
	first:=Ordered_Job{&ordered,1}
	last:=Ordered_Job{&ordered,2}
	if !testing.expect(t,submit(pool,&group,ordered_job,&first)) {return}
	watch:=Batch_Watchdog{blocks=blocks[:]}
	watch_thread:=start_batch_watchdog(&watch)
	if !testing.expect(t,watch_thread!=nil) {return}
	batch:=Mixed_Batch{pool=pool,group=&group,queued=&last}
	parallel_for(pool,len(batch.values),mixed_batch_item,&batch)
	sync.sema_post(&watch.finished)
	thread.destroy(watch_thread)
	testing.expect(t,!watch.expired && batch.submitted,"internal runners can be removed between foreign queued jobs")
	for value in batch.values {testing.expect(t,value==1)}
	if !watch.expired {
		testing.expect(t,ordered.count==0,"parallel_for does not run arbitrary queued callbacks on the caller")
		sync.mutex_lock(&pool.mutex)
		queued:=pool.count
		sync.mutex_unlock(&pool.mutex)
		testing.expect(t,queued==2,"both accepted foreign jobs remain queued")
	}
	sync.sema_post(&blocks[0].release)
	wait(&group)
	testing.expect(t,ordered.count==2 && ordered.values==[2]int{1,2},"compaction preserves FIFO, including a wrapped queue")
	testing.expect(t,ordered.on_worker==[2]bool{true,true},"ordinary accepted callbacks retain worker execution")
}
