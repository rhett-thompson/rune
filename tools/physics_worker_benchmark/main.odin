// Compare Rune's synchronous 3D physics stage with Box3D's native scheduler.
package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "rune:ecs"
import b3 "vendor:box3d"

Body_Count :: 512
Worker_Counts :: [4]int{1,2,4,8}

Settings :: struct {warmup, steps, trials: int, output: string}
Summary :: struct {mean_ms, p95_ms, max_ms: f64}
Trial :: struct {
	trial, actual_worker_count, body_count, shape_count, contacts, awake_contacts: int,
	valid: bool,
	max_reference_position_delta: f32,
	step: Summary,
	raw_step_ms: []f64,
}
Worker_Result :: struct {
	workers, measured_steps: int,
	step, trial_means: Summary,
	trials: [dynamic]Trial,
}
Report :: struct {
	format_version: int,
	scene, measured_stage, clock, os, arch, compiler, compiler_hash, optimization, microarch, cpu_description: string,
	dynamic_bodies, static_bodies, warmup_steps, measured_steps_per_trial, trials_per_worker: int,
	fixed_delta_seconds: f32,
	sleeping_enabled: bool,
	position_tolerance: f32,
	correctness_passed: bool,
	results: [4]Worker_Result,
}

summary :: proc(values: []f64, allocator: mem.Allocator) -> Summary {
	if len(values) == 0 {return {}}
	ordered := make([]f64,len(values),allocator); defer delete(ordered,allocator)
	copy(ordered,values)
	sum: f64
	for value in ordered {sum += value}
	slice.sort(ordered)
	return {sum/f64(len(ordered)),ordered[(len(ordered)*95+99)/100-1],ordered[len(ordered)-1]}
}

settings :: proc() -> (Settings,bool) {
	result := Settings{warmup=120,steps=360,trials=3,output="build/physics-worker-benchmark.json"}
	for argument in os.args[1:] {
		if strings.has_prefix(argument,"--out=") {result.output=argument[len("--out="):];continue}
		matched := false
		for option,index in ([3]string{"--warmup=","--steps=","--trials="}) {
			if !strings.has_prefix(argument,option) {continue}
			value,valid := strconv.parse_int(argument[len(option):])
			if !valid {return {},false}
			switch index {case 0:result.warmup=value;case 1:result.steps=value;case 2:result.trials=value}
			matched=true;break
		}
		if !matched {return {},false}
	}
	return result, result.warmup>=60 && result.warmup<=3600 && result.steps>=120 && result.steps<=3600 &&
		result.trials>=3 && result.trials<=20 && len(result.output)>0
}

// Flush one added body at a time so native insertion order is independent of
// Rune's map iteration order and of each fresh World's generation-bound IDs.
flush_body :: proc(world: ^ecs.World) {
	ecs.physics_3d_raycast(world,{100,100,100},{0,-1,0})
}

add_static :: proc(world: ^ecs.World, registry: ^ecs.Component_Registry, position,size: [3]f32) {
	entity := ecs.create_entity(world)
	assert(ecs.add(world,registry,entity,ecs.Transform{position=position,scale={1,1,1}}))
	assert(ecs.add(world,registry,entity,ecs.BoxCollider{size=size,is_static=true,friction=0.6}))
	flush_body(world)
}

run_trial :: proc(config: Settings, workers, trial: int, reference: []ecs.Transform, allocator: mem.Allocator) -> Trial {
	world := ecs.init(); defer ecs.destroy(&world)
	registry := ecs.init_registry(); defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	assert(ecs.configure_physics_3d(&world,workers))
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch); defer mem.dynamic_arena_destroy(&scratch)
	previous_temp := context.temp_allocator
	context.temp_allocator=mem.dynamic_arena_allocator(&scratch)
	defer context.temp_allocator=previous_temp
	add_static(&world,&registry,{0,-0.5,0},{24,1,24})
	add_static(&world,&registry,{-12.5,10,0},{1,20,26})
	add_static(&world,&registry,{12.5,10,0},{1,20,26})
	add_static(&world,&registry,{0,10,-12.5},{24,20,1})
	add_static(&world,&registry,{0,10,12.5},{24,20,1})
	bodies: [Body_Count]ecs.Entity
	for &entity,index in bodies {
		entity=ecs.create_entity(&world)
		assert(ecs.add(&world,&registry,entity,ecs.Transform{
			position={f32(index%8)*1.05-3.675,0.55+f32(index/64)*1.05,f32((index/8)%8)*1.05-3.675},
			rotation={0,f32(index%7)*3,0},scale={1,1,1},
		}))
		assert(ecs.add(&world,&registry,entity,ecs.BoxCollider{size={0.9,0.9,0.9},friction=0.6}))
		assert(ecs.add(&world,&registry,entity,ecs.RigidBody3D{body_type="dynamic",gravity_scale=1}))
		flush_body(&world)
	}
	// Keep contact solving active throughout the measurement rather than
	// benchmarking mostly sleeping bodies after the warmup settles the stacks.
	b3.World_EnableSleeping(world.box3d_world,false)
	for _ in 0..<config.warmup {
		ecs.physics_3d_update(&world,ecs.Physics3D_Fixed_Delta)
		mem.dynamic_arena_reset(&scratch)
	}
	result := Trial{trial=trial,actual_worker_count=int(b3.World_GetWorkerCount(world.box3d_world)),valid=true,
		raw_step_ms=make([]f64,config.steps,allocator)}
	for &elapsed in result.raw_step_ms {
		started := time.tick_now()
		ecs.physics_3d_update(&world,ecs.Physics3D_Fixed_Delta)
		elapsed=time.duration_milliseconds(time.tick_since(started))
		mem.dynamic_arena_reset(&scratch)
	}
	result.step=summary(result.raw_step_ms,allocator)
	counters,has_counters := ecs.physics_3d_counters(&world)
	result.body_count=int(counters.bodyCount)
	result.shape_count=int(counters.shapeCount)
	result.contacts=int(counters.contactCount)
	result.awake_contacts=int(counters.awakeContactCount)
	result.valid=has_counters && result.actual_worker_count==workers && result.body_count==Body_Count+5 &&
		result.shape_count==Body_Count+5 && result.contacts>0 && result.awake_contacts>0
	for entity,index in bodies {
		pose,found := ecs.get_transform(&world,entity)
		body,has_body := ecs.get(&world,entity,ecs.RigidBody3D)
		result.valid=result.valid && found && has_body && pose.position.y > -0.5 && pose.position.y < 20 &&
			abs(pose.position.x)<12.5 && abs(pose.position.z)<12.5
		for component in pose.position {if math.is_nan(component) || math.is_inf(component) {result.valid=false}}
		for component in pose.rotation {if math.is_nan(component) || math.is_inf(component) {result.valid=false}}
		for component in body.velocity {if math.is_nan(component) || math.is_inf(component) {result.valid=false}}
		if trial==0 && workers==1 {reference[index]=pose}
		for axis in 0..<3 {result.max_reference_position_delta=max(result.max_reference_position_delta,abs(pose.position[axis]-reference[index].position[axis]))}
	}
	result.valid=result.valid && result.max_reference_position_delta<=0.01
	return result
}

main :: proc() {
	when ODIN_OPTIMIZATION_MODE < .Speed {
		fmt.eprintln("Build this benchmark with -o:speed (or -o:aggressive).")
		os.exit(2)
	}
	config,valid := settings()
	if !valid {fmt.eprintln("Usage: physics-worker-benchmark [--out=path.json] [--warmup=60..3600] [--steps=120..3600] [--trials=3..20]");os.exit(2)}
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena); defer mem.dynamic_arena_destroy(&arena)
	allocator:=mem.dynamic_arena_allocator(&arena)
	report:=Report{format_version=1,scene="512-box-stacks-v1",measured_stage="ecs.physics_3d_update (body sync, native step, events, pose sync, controllers)",
		clock="core:time monotonic tick",os=ODIN_OS_STRING,arch=ODIN_ARCH_STRING,compiler=ODIN_VERSION,compiler_hash=ODIN_VERSION_HASH,
		optimization=fmt.aprintf("%v",ODIN_OPTIMIZATION_MODE,allocator=allocator),microarch=ODIN_MICROARCH_STRING,
		cpu_description=os.get_env("PROCESSOR_IDENTIFIER",allocator),dynamic_bodies=Body_Count,static_bodies=5,
		warmup_steps=config.warmup,measured_steps_per_trial=config.steps,trials_per_worker=config.trials,
		fixed_delta_seconds=ecs.Physics3D_Fixed_Delta,sleeping_enabled=false,position_tolerance=0.01,correctness_passed=true}
	reference:=make([]ecs.Transform,Body_Count,allocator)
	worker_counts:=Worker_Counts
	for workers,index in worker_counts {report.results[index].workers=workers;report.results[index].trials=make([dynamic]Trial,allocator)}
	// Rotate the first worker count each trial to reduce consistent ordering
	// bias. Each trial still starts from the same native insertion sequence.
	for trial in 0..<config.trials {
		for offset in 0..<len(Worker_Counts) {
			index:=(offset+trial)%len(Worker_Counts)
			workers:=worker_counts[index]
			result:=run_trial(config,workers,trial,reference,allocator)
			append(&report.results[index].trials,result)
			report.correctness_passed=report.correctness_passed && result.valid
			fmt.printf("trial %d, workers %d: mean %.4f ms, p95 %.4f ms, max %.4f ms, valid=%t, reference delta=%.6f\n",
				trial+1,workers,result.step.mean_ms,result.step.p95_ms,result.step.max_ms,result.valid,result.max_reference_position_delta)
		}
	}
	for &result in report.results {
		all_steps:=make([dynamic]f64,allocator)
		trial_means:=make([dynamic]f64,allocator)
		for trial in result.trials {append(&all_steps,..trial.raw_step_ms);append(&trial_means,trial.step.mean_ms)}
		result.measured_steps=len(all_steps)
		result.step=summary(all_steps[:],allocator)
		result.trial_means=summary(trial_means[:],allocator)
		fmt.printf("workers %d: pooled mean %.4f ms, p95 %.4f ms, max %.4f ms (%d measured steps)\n",
			result.workers,result.step.mean_ms,result.step.p95_ms,result.step.max_ms,result.measured_steps)
	}
	parent:=filepath.dir(config.output)
	if parent!="" {assert(os.make_directory(parent)==nil || os.is_dir(parent),"could not create report directory")}
	encoded,error:=json.marshal(report,{pretty=true,use_spaces=true},allocator=allocator)
	assert(error==nil && os.write_entire_file(config.output,encoded)==nil,"could not write report")
	fmt.printf("Report: %s (correctness=%t)\n",config.output,report.correctness_passed)
	if !report.correctness_passed {os.exit(1)}
}
