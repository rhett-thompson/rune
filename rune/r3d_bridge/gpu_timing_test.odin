package r3d_bridge

import "core:testing"

// A fake driver proves that a busy GPU never triggers a blocking result read.
gpu_query_test: struct {ready:bool,reads,stamps:int}
test_query_available :: proc "c" (id,target:u32,value:^u32) {value^=1 if gpu_query_test.ready else 0}
test_query_result :: proc "c" (id,target:u32,value:^u64) {gpu_query_test.reads+=1; value^=u64(id)*1_000_000}
test_query_stamp :: proc "c" (id,target:u32) {gpu_query_test.stamps+=1}

@(test)
gpu_timing_never_reads_unavailable_queries :: proc(t:^testing.T) {
	gpu_query_test={}
	ctx:=Context{gpu_timing_enabled=true}
	timer:=&ctx.gpu_timing
	timer.attempted=true; timer.supported=true
	timer.api.available=test_query_available; timer.api.result=test_query_result; timer.api.stamp=test_query_stamp
	for &slot,i in timer.slots {slot.ids={u32(i*2+1),u32(i*2+2)}; slot.pending=true; slot.frame=u64(i+1)}
	timer.frame=8
	prepare_gpu_timing(&ctx)
	testing.expect(t,gpu_query_test.reads==0 && !ctx.frame_stats.gpu_ready)
	testing.expect(t,begin_gpu_timing(&ctx)==-1 && gpu_query_test.stamps==0,"a full ring drops its sample")
	gpu_query_test.ready=true; prepare_gpu_timing(&ctx)
	testing.expect(t,gpu_query_test.reads==16 && timer.samples==8)
	testing.expect(t,ctx.frame_stats.gpu_ready && ctx.frame_stats.gpu_sample_frame==8 && ctx.frame_stats.gpu_backend_ms==1)
	index:=begin_gpu_timing(&ctx); end_gpu_timing(&ctx,index)
	testing.expect(t,index>=0 && gpu_query_test.stamps==2 && timer.slots[index].pending)
	ctx.gpu_timing_enabled=false; gpu_query_test.reads=0; prepare_gpu_timing(&ctx)
	testing.expect(t,gpu_query_test.reads==0 && begin_gpu_timing(&ctx)==-1)
	ctx.gpu_timing_enabled=true; timer.supported=false; prepare_gpu_timing(&ctx)
	testing.expect(t,gpu_query_test.reads==0 && begin_gpu_timing(&ctx)==-1,"unsupported drivers do not call query functions")
}
