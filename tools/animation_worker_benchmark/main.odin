// Headless CPU skeletal sampling, local-pose blending, and hierarchy evaluation.
package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "rune:jobs"
import bridge "rune:r3d_bridge"
import r3d "r3d:r3d"
import rl "vendor:raylib"

Key_Count :: 32
Maximum_Characters :: 128
Character_Counts :: [8]int{1,2,4,8,16,32,64,128}
Worker_Counts :: [3]int{0,1,3}
Warmup_Rounds :: 3
Measured_Rounds :: 15
Iterations_Per_Sample :: 8

Fixture :: struct {
	work: []bridge.Animation_Pose_Work,
	bones: []r3d.BoneInfo,
	channels: []r3d.AnimationChannel,
	clips: []r3d.Animation,
	states: []r3d.AnimationState,
	times: []f32,
	translations, scales: []rl.Vector3,
	rotations: []rl.Quaternion,
	local_bind, model_bind, inverse_bind: []rl.Matrix,
	local_pose, model_pose, blend_pose: []rl.Matrix,
	reference_local, reference_model: []rl.Matrix,
	bone_count: int,
}

Result :: struct {
	bones_per_character, characters, total_bones: int,
	blending: bool,
	median_ms: [3]f64,
	speedup: [3]f64,
	samples_ms: [3][]f64,
	pose_equivalence_passed: bool,
}

Report :: struct {
	format_version: int,
	fixture, measured_stage, clock, os, arch, compiler, compiler_hash, optimization, microarch, cpu_description: string,
	keys_per_channel, warmup_rounds, measured_rounds, iterations_per_sample: int,
	worker_counts: [3]int,
	production_threshold_bypassed, native_worker_execution_passed, correctness_passed: bool,
	results: [dynamic]Result,
}

create_fixture :: proc(bone_count:int, blending:bool) -> Fixture {
	f:=Fixture{bone_count=bone_count}
	f.work=make([]bridge.Animation_Pose_Work,Maximum_Characters)
	f.bones=make([]r3d.BoneInfo,bone_count)
	f.channels=make([]r3d.AnimationChannel,bone_count)
	f.clips=make([]r3d.Animation,1)
	f.states=make([]r3d.AnimationState,Maximum_Characters)
	f.times=make([]f32,Key_Count)
	f.translations=make([]rl.Vector3,bone_count*Key_Count)
	f.rotations=make([]rl.Quaternion,bone_count*Key_Count)
	f.scales=make([]rl.Vector3,bone_count*Key_Count)
	f.local_bind=make([]rl.Matrix,bone_count);f.model_bind=make([]rl.Matrix,bone_count);f.inverse_bind=make([]rl.Matrix,bone_count)
	f.local_pose=make([]rl.Matrix,bone_count*Maximum_Characters)
	f.model_pose=make([]rl.Matrix,bone_count*Maximum_Characters)
	f.blend_pose=make([]rl.Matrix,bone_count*Maximum_Characters)
	f.reference_local=make([]rl.Matrix,bone_count*Maximum_Characters)
	f.reference_model=make([]rl.Matrix,bone_count*Maximum_Characters)
	for &tick,index in f.times {tick=f32(index)*2}
	for bone in 0..<bone_count {
		// A short shared spine with dependent limb/finger chains; every parent
		// precedes its descendants, matching the native hierarchy requirement.
		parent:=bone-1
		if bone==0 {parent=-1}
		else if bone>=8 && (bone-8)%6==0 {parent=2+((bone-8)/6)%6}
		f.bones[bone].parent=i32(parent)
		base:=rl.Vector3{f32(bone%3-1)*0.015,0.04+f32(bone%5)*0.005,0.01}
		f.local_bind[bone]=rl.MatrixTranslate(base.x,base.y,base.z)
		f.model_bind[bone]=f.local_bind[bone] if parent<0 else f.local_bind[bone]*f.model_bind[parent]
		f.inverse_bind[bone]=rl.MatrixInvert(f.model_bind[bone])
		for key in 0..<Key_Count {
			i:=bone*Key_Count+key
			phase:=f32(key)*f32(2*math.PI)/f32(Key_Count-1)+f32(bone)*0.17
			f.translations[i]=base+rl.Vector3{math.sin(phase)*0.015,math.cos(phase*0.7)*0.01,math.sin(phase*0.5)*0.02}
			f.rotations[i]=rl.QuaternionFromAxisAngle({0.2+f32(bone%3)*0.1,1,0.3},math.sin(phase)*0.35)
			f.scales[i]={1+math.sin(phase)*0.02,1+math.cos(phase)*0.01,1-math.sin(phase)*0.01}
		}
		first,last:=bone*Key_Count,(bone+1)*Key_Count
		f.channels[bone]={boneIndex=i32(bone),
			translation={times=raw_data(f.times),values=cast([^]f32)raw_data(f.translations[first:last]),count=Key_Count},
			rotation={times=raw_data(f.times),values=cast([^]f32)raw_data(f.rotations[first:last]),count=Key_Count},
			scale={times=raw_data(f.times),values=cast([^]f32)raw_data(f.scales[first:last]),count=Key_Count}}
	}
	f.clips[0]={channels=raw_data(f.channels),channelCount=i32(bone_count),ticksPerSecond=30,duration=f.times[Key_Count-1],boneCount=i32(bone_count)}
	identity:=rl.Matrix(1)
	skeleton:=r3d.Skeleton{bones=raw_data(f.bones),boneCount=i32(bone_count),localBind=raw_data(f.local_bind),
		modelBind=raw_data(f.model_bind),invBind=raw_data(f.inverse_bind),rootBind=transmute([16]f32)identity}
	for &work,index in f.work {
		first,last:=index*bone_count,(index+1)*bone_count
		f.states[index]={currentTime=0.12+f32(index%7)*0.03,speed=1,play=true,loop=true}
		work.player={animLib={animations=&f.clips[0],count=1},skeleton=skeleton,states=raw_data(f.states[index:index+1]),
			activeAnimIndex=0,localPose=raw_data(f.local_pose[first:last]),modelPose=raw_data(f.model_pose[first:last])}
		if blending {
			r3d.ComputeAnimationLocalPose(&work.player)
			copy(f.blend_pose[first:last],f.local_pose[first:last])
			work.blend_pose=f.blend_pose[first:last];work.blend_weight=0.37
		}
	}
	return f
}

destroy_fixture :: proc(f:^Fixture) {
	// Every buffer is Odin-owned. Native player creation/destruction would
	// create/free GPU objects or cross allocator ownership, so neither is used.
	delete(f.work);delete(f.bones);delete(f.channels);delete(f.clips);delete(f.states);delete(f.times)
	delete(f.translations);delete(f.rotations);delete(f.scales)
	delete(f.local_bind);delete(f.model_bind);delete(f.inverse_bind)
	delete(f.local_pose);delete(f.model_pose);delete(f.blend_pose);delete(f.reference_local);delete(f.reference_model)
	f^={}
}

evaluate :: proc(work:[]bridge.Animation_Pose_Work,pool:^jobs.Pool) {
	if pool==nil {for &item in work {bridge.evaluate_animation_pose(&item)};return}
	batch:=bridge.Animation_Pose_Batch{work=work}
	jobs.parallel_for(pool,len(work),bridge.animation_pose_job,&batch)
}

check_poses :: proc(f:^Fixture,characters:int) -> bool {
	for i in 0..<characters*f.bone_count {
		if f.local_pose[i]!=f.reference_local[i] || f.model_pose[i]!=f.reference_model[i] {return false}
	}
	return true
}

Worker_Probe_Gate :: struct {started,release:sync.Sema}
Worker_Probe :: struct {
	gate:^Worker_Probe_Gate,
	work:^bridge.Animation_Pose_Work,
	epoch:time.Tick,
	thread_id:int,
	begin,end:time.Duration,
}

worker_probe :: proc(data:rawptr) {
	probe:=(^Worker_Probe)(data)
	probe.thread_id=os.get_current_thread_id()
	sync.sema_post(&probe.gate.started)
	sync.sema_wait(&probe.gate.release)
	probe.begin=time.tick_since(probe.epoch)
	for _ in 0..<128 {bridge.evaluate_animation_pose(probe.work)}
	probe.end=time.tick_since(probe.epoch)
}

verify_worker_execution :: proc(f:^Fixture,pool:^jobs.Pool) -> bool {
	evaluate(f.work[:2],nil)
	copy(f.reference_local,f.local_pose);copy(f.reference_model,f.model_pose)
	gate:Worker_Probe_Gate;group:jobs.Group
	probes:=[2]Worker_Probe{{gate=&gate,work=&f.work[0],epoch=time.tick_now()},{gate=&gate,work=&f.work[1],epoch=time.tick_now()}}
	probes[1].epoch=probes[0].epoch
	accepted:=true
	for &probe in probes {accepted=jobs.submit(pool,&group,worker_probe,&probe) && accepted}
	ready:=accepted
	if accepted {for _ in 0..<2 {ready=sync.sema_wait_with_timeout(&gate.started,5*time.Second) && ready}}
	sync.sema_post(&gate.release,2);jobs.wait(&group)
	owner:=os.get_current_thread_id()
	overlapped:=max(probes[0].begin,probes[1].begin)<min(probes[0].end,probes[1].end)
	return ready && probes[0].thread_id!=owner && probes[1].thread_id!=owner && probes[0].thread_id!=probes[1].thread_id && overlapped && check_poses(f,2)
}

run_case :: proc(f:^Fixture,characters:int,blending:bool,pools:[3]^jobs.Pool,allocator:mem.Allocator) -> Result {
	result:=Result{bones_per_character=f.bone_count,characters=characters,total_bones=f.bone_count*characters,blending=blending,pose_equivalence_passed=true}
	for &samples in result.samples_ms {samples=make([]f64,Measured_Rounds,allocator)}
	work:=f.work[:characters]
	for round in 0..<Warmup_Rounds+Measured_Rounds {
		for &state,index in f.states[:characters] {state.currentTime=0.05+f32((round*7+index*11)%59)/30}
		// Untimed reference for this round's independently sampled character times.
		evaluate(work,nil)
		copy(f.reference_local,f.local_pose);copy(f.reference_model,f.model_pose)
		for offset in 0..<len(pools) {
			method:=(offset+round)%len(pools)
			started:=time.tick_now()
			for _ in 0..<Iterations_Per_Sample {evaluate(work,pools[method])}
			elapsed:=time.duration_milliseconds(time.tick_since(started))/f64(Iterations_Per_Sample)
			result.pose_equivalence_passed=result.pose_equivalence_passed && check_poses(f,characters)
			if round>=Warmup_Rounds {result.samples_ms[method][round-Warmup_Rounds]=elapsed}
		}
	}
	for values,index in result.samples_ms {
		ordered:=make([]f64,len(values));copy(ordered,values);slice.sort(ordered)
		result.median_ms[index]=ordered[len(ordered)/2];delete(ordered)
	}
	for elapsed,index in result.median_ms {result.speedup[index]=result.median_ms[0]/elapsed}
	return result
}

cpu_description :: proc(allocator:mem.Allocator) -> string {
	description:=os.get_env("PROCESSOR_IDENTIFIER",allocator)
	when ODIN_OS==.Linux {
		bytes,err:=os.read_entire_file("/proc/cpuinfo",allocator)
		if err==nil {
			defer delete(bytes,allocator)
			for line in strings.split_lines(string(bytes),allocator) {
				if strings.has_prefix(line,"model name") {
					colon:=strings.index_byte(line,':')
					if colon>=0 {description,_=strings.clone(strings.trim_space(line[colon+1:]),allocator);break}
				}
			}
		}
	}
	return description
}

main :: proc() {
	when ODIN_OPTIMIZATION_MODE<.Speed {fmt.eprintln("Build this benchmark with -o:speed.");os.exit(2)}
	output:="build/animation-worker-benchmark.json"
	for argument in os.args[1:] {
		if !strings.has_prefix(argument,"--out=") {fmt.eprintln("Usage: animation_worker_benchmark [--out=report.json]");os.exit(2)}
		output=argument[len("--out="):]
	}
	assert(output!="")
	arena:mem.Dynamic_Arena;mem.dynamic_arena_init(&arena);defer mem.dynamic_arena_destroy(&arena)
	a:=mem.dynamic_arena_allocator(&arena)
	pools:=[3]^jobs.Pool{nil,jobs.create(1,64),jobs.create(3,64)}
	assert(pools[1]!=nil && pools[2]!=nil)
	defer jobs.destroy(pools[1]);defer jobs.destroy(pools[2])
	report:=Report{format_version=1,fixture="keyed-hierarchy-pose-v1",measured_stage="native local sampling, optional Rune TRS blend, native model hierarchy, dispatch and barrier",
		clock="core:time monotonic tick",os=ODIN_OS_STRING,arch=ODIN_ARCH_STRING,compiler=ODIN_VERSION,compiler_hash=ODIN_VERSION_HASH,
		optimization=fmt.aprintf("%v",ODIN_OPTIMIZATION_MODE,allocator=a),microarch=ODIN_MICROARCH_STRING,cpu_description=cpu_description(a),
		keys_per_channel=Key_Count,warmup_rounds=Warmup_Rounds,measured_rounds=Measured_Rounds,iterations_per_sample=Iterations_Per_Sample,
		worker_counts=Worker_Counts,production_threshold_bypassed=true,native_worker_execution_passed=true,correctness_passed=true,results=make([dynamic]Result,a)}
	fmt.println("bones characters blend | serial_ms 1worker_ms 3workers_ms | speedup1 speedup3 | exact_pose_match")
	for bone_count in ([2]int{64,128}) {for blending in ([2]bool{false,true}) {
		fixture:=create_fixture(bone_count,blending)
		report.native_worker_execution_passed=verify_worker_execution(&fixture,pools[2]) && report.native_worker_execution_passed
		for characters in Character_Counts {
			result:=run_case(&fixture,characters,blending,pools,a)
			append(&report.results,result)
			report.correctness_passed=report.correctness_passed && result.pose_equivalence_passed
			fmt.printf("%3d %3d %5t | %.5f %.5f %.5f | %.2fx %.2fx | %t\n",bone_count,characters,blending,
				result.median_ms[0],result.median_ms[1],result.median_ms[2],result.speedup[1],result.speedup[2],result.pose_equivalence_passed)
		}
		destroy_fixture(&fixture)
	}}
	report.correctness_passed=report.correctness_passed && report.native_worker_execution_passed
	fmt.printf("Two distinct non-owner workers, overlapping CPU evaluation, exact poses: %t\n",report.native_worker_execution_passed)
	parent:=filepath.dir(output)
	if parent!="" {assert(os.make_directory(parent)==nil || os.is_dir(parent))}
	encoded,err:=json.marshal(report,{pretty=true,use_spaces=true},allocator=a)
	assert(err==nil && os.write_entire_file(output,encoded)==nil)
	fmt.printf("Report: %s (correctness=%t)\n",output,report.correctness_passed)
	if !report.correctness_passed {os.exit(1)}
}
