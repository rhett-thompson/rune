package r3d_bridge

import gl "vendor:OpenGL"
import rlgl "vendor:raylib/rlgl"

Gpu_Query_API :: struct {
	gen: proc "c" (n:i32,ids:^u32),
	delete: proc "c" (n:i32,ids:^u32),
	stamp: proc "c" (id,target:u32),
	available: proc "c" (id,target:u32,value:^u32),
	result: proc "c" (id,target:u32,value:^u64),
}
Gpu_Query_Slot :: struct {ids:[2]u32,frame:u64,pending:bool}
Gpu_Timing :: struct {
	api: Gpu_Query_API,
	slots: [8]Gpu_Query_Slot,
	attempted,supported,ready: bool,
	frame,sample_frame,samples: u64,
	backend_ms: f64,
}

release_gpu_timing :: proc(ctx:^Context) {
	t:=&ctx.gpu_timing
	if t.supported {for &slot in t.slots {t.api.delete(2,&slot.ids[0])}}
	t^={}
}

prepare_gpu_timing :: proc(ctx:^Context) {
	t:=&ctx.gpu_timing; t.frame+=1
	if !ctx.gpu_timing_enabled {return}
	if !t.attempted {
		t.attempted=true
		t.api.gen=transmute(type_of(t.api.gen))rlgl.GetProcAddress("glGenQueries")
		t.api.delete=transmute(type_of(t.api.delete))rlgl.GetProcAddress("glDeleteQueries")
		t.api.stamp=transmute(type_of(t.api.stamp))rlgl.GetProcAddress("glQueryCounter")
		t.api.available=transmute(type_of(t.api.available))rlgl.GetProcAddress("glGetQueryObjectuiv")
		t.api.result=transmute(type_of(t.api.result))rlgl.GetProcAddress("glGetQueryObjectui64v")
		t.supported=t.api.gen!=nil && t.api.delete!=nil && t.api.stamp!=nil && t.api.available!=nil && t.api.result!=nil
		if t.supported {for &slot in t.slots {t.api.gen(2,&slot.ids[0])}}
	}
	if !t.supported {return}
	for &slot in t.slots {
		if !slot.pending {continue}
		available:u32; t.api.available(slot.ids[1],gl.QUERY_RESULT_AVAILABLE,&available)
		if available==0 {continue} // Never request an unavailable result or wait.
		start,end:u64
		t.api.result(slot.ids[0],gl.QUERY_RESULT,&start)
		t.api.result(slot.ids[1],gl.QUERY_RESULT,&end)
		if end>=start && slot.frame>=t.sample_frame {
			t.backend_ms=f64(end-start)/1e6; t.sample_frame=slot.frame; t.ready=true
		}
		t.samples+=1; slot.pending=false
	}
	ctx.frame_stats.gpu_supported=t.supported
	ctx.frame_stats.gpu_ready=t.ready
	ctx.frame_stats.gpu_backend_ms=t.backend_ms
	ctx.frame_stats.gpu_sample_frame=t.sample_frame
	ctx.frame_stats.gpu_sample_age_frames=t.frame-t.sample_frame if t.ready else 0
	ctx.frame_stats.gpu_samples=t.samples
}

begin_gpu_timing :: proc(ctx:^Context) -> int {
	t:=&ctx.gpu_timing
	if !ctx.gpu_timing_enabled || !t.supported {return -1}
	for &slot,i in t.slots {
		if slot.pending {continue}
		slot.frame=t.frame; t.api.stamp(slot.ids[0],gl.TIMESTAMP)
		return i
	}
	return -1 // A backed-up GPU drops samples instead of stalling the CPU.
}

end_gpu_timing :: proc(ctx:^Context,index:int) {
	if index<0 {return}
	t:=&ctx.gpu_timing; slot:=&t.slots[index]
	t.api.stamp(slot.ids[1],gl.TIMESTAMP); slot.pending=true
}
