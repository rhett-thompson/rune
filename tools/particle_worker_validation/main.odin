package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"
import "rune:jobs"
import rl "vendor:raylib"

Gate :: struct {started,release:sync.Sema}
hold :: proc(data:rawptr) {gate:=(^Gate)(data);sync.sema_post(&gate.started);sync.sema_wait(&gate.release)}
increment :: proc(data:rawptr) {(^int)(data)^+=1}
Watchdog :: struct {finished:sync.Sema,gate:^Gate,expired:bool}
watchdog :: proc(worker:^thread.Thread) {
	watch:=(^Watchdog)(worker.data)
	if !sync.sema_wait_with_timeout(&watch.finished,2*time.Second) {watch.expired=true;sync.sema_post(&watch.gate.release)}
}

// Check both rejected runner admission and accepted-but-unused runner cleanup.
// A watchdog makes a scheduler regression fail instead of hanging the tool.
with_busy_pool :: proc(full:bool,callback:proc(pool:^jobs.Pool,data:rawptr),data:rawptr) {
	pool:=jobs.create(1,1);assert(pool!=nil);defer jobs.destroy(pool)
	gate:Gate;group,queued:jobs.Group;writes:int
	assert(jobs.submit(pool,&group,hold,&gate));assert(sync.sema_wait_with_timeout(&gate.started,2*time.Second))
	if full {assert(jobs.submit(pool,&queued,increment,&writes))}
	watch:=Watchdog{gate=&gate};worker:=thread.create(watchdog);assert(worker!=nil)
	worker.data=&watch;thread.start(worker)
	callback(pool,data)
	sync.sema_post(&watch.finished);thread.destroy(worker)
	assert(!watch.expired && !jobs.is_complete(&group),"the CPU batch returns while unrelated work remains blocked")
	assert(writes==0,"caller help never runs foreign queued callbacks")
	sync.sema_post(&gate.release);jobs.wait(&group);jobs.wait(&queued)
	assert(!full || writes==1)
}

hash_bytes :: proc(bytes:[]u8) -> u64 {
	hash:=u64(14695981039346656037)
	for byte in bytes {hash=(hash ~ u64(byte))*1099511628211}
	return hash
}

image_hash :: proc(image:rl.Image) -> (u64,int) {
	assert(image.data!=nil)
	colors:=rl.LoadImageColors(image);defer rl.UnloadImageColors(colors)
	visible:=0
	for color in colors[:int(image.width*image.height)] {if color.r>10 || color.g>10 || color.b>10 {visible+=1}}
	return hash_bytes(mem.slice_to_bytes(colors[:int(image.width*image.height)])),visible
}

main :: proc() {
	runtime:=false
	for arg in os.args[1:] {if arg!="--runtime" {fmt.eprintln("Usage: particle_worker_validation [--runtime]");os.exit(2)};runtime=true}
	arena:mem.Dynamic_Arena;mem.dynamic_arena_init(&arena);defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator=mem.dynamic_arena_allocator(&arena)
	pool:=jobs.create(3,1);assert(pool!=nil);defer jobs.destroy(pool)
	validate_simulation(pool)
	validate_preparation(pool)
	if runtime {rl.SetTraceLogLevel(.WARNING);validate_core_runtime();validate_billboard_runtime(pool)}
	else {fmt.println("Skipped particle GPU checks; pass --runtime with a working display")}
	fmt.println("Particle worker validation passed")
}
