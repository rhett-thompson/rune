// Deterministic CPU particle simulation and billboard preparation; no GL calls.
package main

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "rune:jobs"
import "rune:particles"
import bridge "rune:r3d_bridge"
import rl "vendor:raylib"

Maximum_Particles :: 524288
Worker_Counts :: [3]int{0,1,3}
Warmup_Rounds :: 3
Measured_Rounds :: 15
Iterations_Per_Sample :: 4

Result :: struct {
	stage, blend, scheduling: string,
	batches, initial_particles, final_particles, iterations_per_sample: int,
	median_ms, mean_ms, p95_ms, max_ms, speedup: [3]f64,
	samples_ms: [3][]f64,
	exact_match: bool,
}

Report :: struct {
	format_version: int,
	fixture, selection, clock, os, arch, compiler, compiler_hash, optimization, microarch, cpu_description: string,
	warmup_rounds, measured_rounds, iterations_per_sample: int,
	production_min_work_2d, production_min_count_3d, production_billboard_min, range_size_3d, billboard_chunk_size: int,
	worker_counts: [3]int,
	pooled_thresholds_bypassed: bool,
	worker_execution_2d_passed, worker_execution_3d_passed, worker_execution_billboards_passed: bool,
	worker_execution_passed, correctness_passed: bool,
	results: [dynamic]Result,
}

ensure :: proc(ok:bool,message:string) {
	if !ok {fmt.eprintln(message);os.exit(1)}
}

initialize_result :: proc(stage,blend,scheduling:string,batches,count:int,a:mem.Allocator) -> Result {
	result:=Result{stage=stage,blend=blend,scheduling=scheduling,batches=batches,initial_particles=count,iterations_per_sample=Iterations_Per_Sample,exact_match=true}
	for &samples in result.samples_ms {samples=make([]f64,Measured_Rounds,a)}
	return result
}

finish_result :: proc(result:^Result) {
	for values,index in result.samples_ms {
		ordered:=make([]f64,len(values));copy(ordered,values);slice.sort(ordered)
		for value in values {result.mean_ms[index]+=value/f64(len(values))}
		result.median_ms[index]=ordered[len(ordered)/2]
		result.p95_ms[index]=ordered[(len(ordered)*95+99)/100-1]
		result.max_ms[index]=ordered[len(ordered)-1]
		delete(ordered)
	}
	for elapsed,index in result.median_ms {result.speedup[index]=result.median_ms[0]/elapsed}
}

Fixture_2D :: struct {
	seed, current, reference: []particles.State,
	work, reference_work: []particles.Update_2D_Work,
}

copy_state :: proc(destination:^particles.State,source:particles.State,capacity:int) {
	reserve(&destination.particles,capacity)
	resize(&destination.particles,len(source.particles))
	copy(destination.particles[:],source.particles[:])
	destination.credit=source.credit;destination.random=source.random;destination.initialized=source.initialized
}

create_2d :: proc(emitters,per_emitter:int) -> Fixture_2D {
	f:=Fixture_2D{seed=make([]particles.State,emitters),current=make([]particles.State,emitters),reference=make([]particles.State,emitters),
		work=make([]particles.Update_2D_Work,emitters),reference_work=make([]particles.Update_2D_Work,emitters)}
	for &seed,index in f.seed {
		settings:=particles.defaults()
		settings.max_particles=i32(per_emitter+64);settings.seed=u32(1729+index*97)
		settings.rate=f32(180+index%7*19);settings.lifetime={0.7,2.4};settings.gravity={3,24};settings.speed={10,70}
		settings.start_size=3;settings.end_size=0.1
		ensure(particles.emit(&seed,settings,per_emitter,{f32(index)*3,-2})==per_emitter,"Could not create the complete 2D fixture.")
		for &p,i in seed.particles {p.age=p.lifetime*f32(i%103)/104}
		seed.credit=0.37
		copy_state(&f.current[index],seed,int(settings.max_particles));copy_state(&f.reference[index],seed,int(settings.max_particles))
		f.work[index]={state=&f.current[index],settings=settings,origin={f32(index)*3,-2},rotation=f32(index%9),scale=1}
		f.reference_work[index]=f.work[index];f.reference_work[index].state=&f.reference[index]
	}
	return f
}

destroy_2d :: proc(f:^Fixture_2D) {
	for &state in f.seed {particles.destroy(&state)}
	for &state in f.current {particles.destroy(&state)}
	for &state in f.reference {particles.destroy(&state)}
	delete(f.seed);delete(f.current);delete(f.reference);delete(f.work);delete(f.reference_work);f^={}
}

reset_2d :: proc(f:^Fixture_2D,reference:bool) {
	states:=f.reference if reference else f.current
	for &state,index in states {copy_state(&state,f.seed[index],int(f.work[index].settings.max_particles))}
}

evaluate_2d :: proc(work:[]particles.Update_2D_Work,dt:f32,pool:^jobs.Pool) {
	if pool==nil {
		for item in work {particles.update(item.state,item.settings,dt,item.origin,item.rotation,item.scale)}
		return
	}
	for item in work {ensure(particles.prepare_update(item.state,item.settings,dt),"Could not prepare 2D particle storage.")}
	batch:=particles.Update_2D_Batch{work,dt}
	jobs.parallel_for(pool,len(work),particles.update_2d_job,&batch)
}

check_2d :: proc(f:^Fixture_2D) -> bool {
	for state,index in f.current {
		reference:=f.reference[index]
		if state.credit!=reference.credit || state.random!=reference.random || state.initialized!=reference.initialized || len(state.particles)!=len(reference.particles) {return false}
		for p,i in state.particles {if p!=reference.particles[i] {return false}}
	}
	return true
}

run_2d :: proc(emitters,per_emitter:int,pools:[3]^jobs.Pool,a:mem.Allocator) -> Result {
	f:=create_2d(emitters,per_emitter);defer destroy_2d(&f)
	result:=initialize_result("simulation_2d","none","raw emitter jobs; original scalar baseline; owner prepare included",emitters,emitters*per_emitter,a)
	for round in 0..<Warmup_Rounds+Measured_Rounds {
		dt:=f32(1)/f32(120-(round%3)*20)
		reset_2d(&f,true)
		for _ in 0..<Iterations_Per_Sample {evaluate_2d(f.reference_work,dt,nil)}
		for offset in 0..<len(pools) {
			method:=(round+offset)%len(pools)
			reset_2d(&f,false)
			started:=time.tick_now()
			for _ in 0..<Iterations_Per_Sample {evaluate_2d(f.work,dt,pools[method])}
			elapsed:=time.duration_milliseconds(time.tick_since(started))/f64(Iterations_Per_Sample)
			result.exact_match=check_2d(&f) && result.exact_match
			if round>=Warmup_Rounds {result.samples_ms[method][round-Warmup_Rounds]=elapsed}
		}
	}
	for state in f.reference {result.final_particles+=len(state.particles)}
	finish_result(&result);return result
}

create_3d_seed :: proc(count:int) -> []particles.Particle3D {
	pool:=new(particles.Pool3D(Maximum_Particles));defer free(pool)
	settings:=particles.Burst3D{lifetime={0.7,2.4},speed={2,12},spread=180,gravity={1,-8,0.3},start_size=0.3,end_size=0,
		start_color={255,180,60,230},end_color={80,20,255,0},seed=1729}
	ensure(particles.emit_burst_3d(pool,settings,count,{0,1,-5},{0,1,0})==count,"Could not create the complete 3D fixture.")
	seed:=make([]particles.Particle3D,count);copy(seed,pool.particles[:count])
	for &p,index in seed {p.age=p.lifetime*f32(index%103)/104}
	return seed
}

evaluate_3d :: proc(live:[]particles.Particle3D,dt:f32,pool:^jobs.Pool) -> int {
	if pool==nil {return particles.update_3d_slice(live,dt)}
	batch:=particles.Update_3D_Batch{live,dt}
	ranges:=(len(live)+particles.Update_3D_Range_Size-1)/particles.Update_3D_Range_Size
	jobs.parallel_for(pool,ranges,particles.update_3d_range_job,&batch)
	return particles.compact_3d_slice(live)
}

equal_3d :: proc(a,b:[]particles.Particle3D) -> bool {
	if len(a)!=len(b) {return false}
	for p,index in a {if p!=b[index] {return false}}
	return true
}

run_3d :: proc(count:int,pools:[3]^jobs.Pool,a:mem.Allocator) -> Result {
	seed:=create_3d_seed(count);defer delete(seed)
	current:=make([]particles.Particle3D,count);defer delete(current)
	reference:=make([]particles.Particle3D,count);defer delete(reference)
	result:=initialize_result("simulation_3d","none","raw 1024-particle ranges plus owner compaction; original single-pass scalar baseline",1,count,a)
	for round in 0..<Warmup_Rounds+Measured_Rounds {
		dt:=f32(1)/f32(120-(round%3)*20)
		copy(reference,seed);reference_count:=count
		for _ in 0..<Iterations_Per_Sample {reference_count=evaluate_3d(reference[:reference_count],dt,nil)}
		for offset in 0..<len(pools) {
			method:=(round+offset)%len(pools)
			copy(current,seed);live_count:=count
			started:=time.tick_now()
			for _ in 0..<Iterations_Per_Sample {live_count=evaluate_3d(current[:live_count],dt,pools[method])}
			elapsed:=time.duration_milliseconds(time.tick_since(started))/f64(Iterations_Per_Sample)
			result.exact_match=equal_3d(current[:live_count],reference[:reference_count]) && result.exact_match
			if round>=Warmup_Rounds {result.samples_ms[method][round-Warmup_Rounds]=elapsed}
		}
		result.final_particles=reference_count
	}
	finish_result(&result);return result
}

destroy_billboard :: proc(state:^bridge.Particle_Billboard_Batch) {
	delete(state.instances);delete(state.positions);delete(state.scales);delete(state.colors);state^={}
}

equal_billboard :: proc(a,b:^bridge.Particle_Billboard_Batch) -> bool {
	if len(a.instances)!=len(b.instances) || len(a.positions)!=len(b.positions) || len(a.scales)!=len(b.scales) || len(a.colors)!=len(b.colors) {return false}
	for value,index in a.instances {if value!=b.instances[index] {return false}}
	for value,index in a.positions {if value!=b.positions[index] || a.scales[index]!=b.scales[index] || a.colors[index]!=b.colors[index] {return false}}
	return true
}

evaluate_billboards :: proc(work:[]bridge.Particle_Billboard_Work,pool:^jobs.Pool) {
	if pool==nil {bridge.prepare_particle_billboard_work(work,nil);return}
	chunks,ready:=bridge.prepare_particle_billboard_storage(work)
	batch:=bridge.Particle_Billboard_Prepare_Batch{work}
	if chunks>1 {jobs.parallel_for(pool,chunks,bridge.particle_billboard_range_job,&batch)}
	else if chunks==1 {bridge.particle_billboard_range_job(0,&batch)}
	if ready>1 {jobs.parallel_for(pool,len(work),bridge.particle_billboard_finalize_job,&batch)}
	else {for index in 0..<len(work) {bridge.particle_billboard_finalize_job(index,&batch)}}
}

run_billboards :: proc(count,batches:int,blend:bridge.Particle3D_Blend,pools:[3]^jobs.Pool,a:mem.Allocator) -> Result {
	seed:=create_3d_seed(count);defer delete(seed)
	for &p,index in seed {
		p.position={f32((index*47)%997)*0.07-30,f32((index*19)%211)*0.03-3,-f32((index*61)%811)*0.09}
		if index%19==0 {p.position={0,0,-8}}
		if index%23==0 {p.lifetime=0}
		if index%29==0 {p.start_color[3]=0;p.end_color[3]=0}
		if index%31==0 {p.start_size=0;p.end_size=0}
	}
	input_copy:=make([]particles.Particle3D,count);defer delete(input_copy);copy(input_copy,seed)
	states:=make([]bridge.Particle_Billboard_Batch,batches);defer delete(states)
	references:=make([]bridge.Particle_Billboard_Batch,batches);defer delete(references)
	defer {for &state in states {destroy_billboard(&state)};for &state in references {destroy_billboard(&state)}}
	work:=make([]bridge.Particle_Billboard_Work,batches);defer delete(work)
	reference_work:=make([]bridge.Particle_Billboard_Work,batches);defer delete(reference_work)
	for &item,index in work {
		first,last:=index*count/batches,(index+1)*count/batches
		item={state=&states[index],batch={particles=seed[first:last],shape=.Billboard,blend=blend},camera={position={1,2,8},target={-1,0,-4},up={0,1,0}}}
		reference_work[index]=item;reference_work[index].state=&references[index]
	}
	result:=initialize_result("billboard_prepare","alpha" if blend==.Alpha else "additive","raw chunk helpers including warm storage setup, filtering, ordered merge, alpha sort, SoA packing and both barriers",batches,count,a)
	// Large alpha sorts already provide long samples; avoid multiplying them
	// merely to average timer overhead that is negligible at this scale.
	if blend==.Alpha && count>=32768 {result.iterations_per_sample=1}
	for round in 0..<Warmup_Rounds+Measured_Rounds {
		for &item,index in work {
			item.camera.position.x=1+f32(round%5)*0.2
			reference_work[index].camera=item.camera
		}
		evaluate_billboards(reference_work,nil)
		for offset in 0..<len(pools) {
			method:=(round+offset)%len(pools)
			started:=time.tick_now()
			for _ in 0..<result.iterations_per_sample {evaluate_billboards(work,pools[method])}
			elapsed:=time.duration_milliseconds(time.tick_since(started))/f64(result.iterations_per_sample)
			for &state,index in states {result.exact_match=equal_billboard(&state,&references[index]) && result.exact_match}
			result.exact_match=equal_3d(seed,input_copy) && result.exact_match
			if round>=Warmup_Rounds {result.samples_ms[method][round-Warmup_Rounds]=elapsed}
		}
	}
	for state in references {result.final_particles+=len(state.instances)}
	finish_result(&result);return result
}

Probe_Gate :: struct {started,release:sync.Sema}
Worker_Probe :: struct {gate:^Probe_Gate,procedure:jobs.Job_Proc,data:rawptr,epoch:time.Tick,thread_id:int,begin,end:time.Duration}

worker_probe :: proc(data:rawptr) {
	probe:=(^Worker_Probe)(data)
	probe.thread_id=os.get_current_thread_id()
	sync.sema_post(&probe.gate.started);sync.sema_wait(&probe.gate.release)
	probe.begin=time.tick_since(probe.epoch)
	probe.procedure(probe.data)
	probe.end=time.tick_since(probe.epoch)
}

verify_pair :: proc(pool:^jobs.Pool,procedure:jobs.Job_Proc,data:[2]rawptr) -> bool {
	gate:Probe_Gate;group:jobs.Group
	epoch:=time.tick_now()
	probes:=[2]Worker_Probe{{gate=&gate,procedure=procedure,data=data[0],epoch=epoch},{gate=&gate,procedure=procedure,data=data[1],epoch=epoch}}
	accepted:=true
	for &probe in probes {accepted=jobs.submit(pool,&group,worker_probe,&probe) && accepted}
	ready:=accepted
	if accepted {for _ in 0..<2 {ready=sync.sema_wait_with_timeout(&gate.started,5*time.Second) && ready}}
	sync.sema_post(&gate.release,2);jobs.wait(&group)
	owner:=os.get_current_thread_id()
	return ready && probes[0].thread_id!=owner && probes[1].thread_id!=owner && probes[0].thread_id!=probes[1].thread_id &&
		max(probes[0].begin,probes[1].begin)<min(probes[0].end,probes[1].end)
}

Probe_Iterations :: 64

probe_2d :: proc(data:rawptr) {for _ in 0..<Probe_Iterations {particles.update_2d_job(0,data)}}

verify_2d_workers :: proc(pool:^jobs.Pool) -> bool {
	f:=create_2d(2,16384);defer destroy_2d(&f)
	dt:=f32(1)/120
	for _ in 0..<Probe_Iterations {evaluate_2d(f.reference_work,dt,nil)}
	for item in f.work {ensure(particles.prepare_update(item.state,item.settings,dt),"Could not prepare the 2D worker probe.")}
	batches:=[2]particles.Update_2D_Batch{{f.work[:1],dt},{f.work[1:],dt}}
	return verify_pair(pool,probe_2d,{&batches[0],&batches[1]}) && check_2d(&f)
}

Probe_3D :: struct {live:[]particles.Particle3D,count:int,dt:f32}

probe_3d :: proc(data:rawptr) {
	probe:=(^Probe_3D)(data)
	for _ in 0..<Probe_Iterations {
		batch:=particles.Update_3D_Batch{probe.live[:probe.count],probe.dt}
		ranges:=(probe.count+particles.Update_3D_Range_Size-1)/particles.Update_3D_Range_Size
		for index in 0..<ranges {particles.update_3d_range_job(index,&batch)}
		probe.count=particles.compact_3d_slice(batch.live)
	}
}

verify_3d_workers :: proc(pool:^jobs.Pool) -> bool {
	seed:=create_3d_seed(65536);defer delete(seed)
	reference:=make([]particles.Particle3D,len(seed));defer delete(reference);copy(reference,seed)
	probes:=[2]Probe_3D{{seed[:32768],32768,1.0/120},{seed[32768:],32768,1.0/120}}
	counts:=[2]int{32768,32768}
	for _ in 0..<Probe_Iterations {for &count,index in counts {count=evaluate_3d(reference[index*32768:index*32768+count],probes[index].dt,nil)}}
	if !verify_pair(pool,probe_3d,{&probes[0],&probes[1]}) {return false}
	for probe,index in probes {if !equal_3d(probe.live[:probe.count],reference[index*32768:index*32768+counts[index]]) {return false}}
	return true
}

Probe_Billboards :: struct {batch:bridge.Particle_Billboard_Prepare_Batch,chunks:int}

probe_billboards :: proc(data:rawptr) {
	probe:=(^Probe_Billboards)(data)
	for _ in 0..<Probe_Iterations {for index in 0..<probe.chunks {bridge.particle_billboard_range_job(index,&probe.batch)}}
	bridge.particle_billboard_finalize_job(0,&probe.batch)
}

verify_billboard_workers :: proc(pool:^jobs.Pool) -> bool {
	seed:=create_3d_seed(65536);defer delete(seed)
	for &p,index in seed {p.position={f32(index%97),f32(index%41),-f32((index*19)%811)}}
	states:[2]bridge.Particle_Billboard_Batch
	references:[2]bridge.Particle_Billboard_Batch
	defer {for &state in states {destroy_billboard(&state)};for &state in references {destroy_billboard(&state)}}
	work:[2]bridge.Particle_Billboard_Work
	probes:[2]Probe_Billboards
	for &item,index in work {
		item={state=&states[index],batch={particles=seed[index*32768:(index+1)*32768],shape=.Billboard,blend=.Alpha},camera={target={0,0,-1}}}
		bridge.prepare_particle_billboards(&references[index],item.batch,item.camera)
		chunk_count,_:=bridge.prepare_particle_billboard_storage(work[index:index+1])
		probes[index]={bridge.Particle_Billboard_Prepare_Batch{work[index:index+1]},chunk_count}
	}
	return verify_pair(pool,probe_billboards,{&probes[0],&probes[1]}) && equal_billboard(&states[0],&references[0]) && equal_billboard(&states[1],&references[1])
}

cpu_description :: proc(a:mem.Allocator) -> string {
	description:=os.get_env("PROCESSOR_IDENTIFIER",a)
	when ODIN_OS==.Linux {
		bytes,err:=os.read_entire_file("/proc/cpuinfo",a)
		if err==nil {
			defer delete(bytes,a)
			for line in strings.split_lines(string(bytes),a) {
				if strings.has_prefix(line,"model name") {
					colon:=strings.index_byte(line,':')
					if colon>=0 {description,_=strings.clone(strings.trim_space(line[colon+1:]),a);break}
				}
			}
		}
	}
	return description
}

record :: proc(report:^Report,result:Result) {
	append(&report.results,result);report.correctness_passed=result.exact_match && report.correctness_passed
	fmt.printf("%s %s %dx%d | %.5f %.5f %.5f | %.2fx %.2fx | exact=%t\n",result.stage,result.blend,result.batches,result.initial_particles/result.batches,
		result.median_ms[0],result.median_ms[1],result.median_ms[2],result.speedup[1],result.speedup[2],result.exact_match)
}

main :: proc() {
	when ODIN_OPTIMIZATION_MODE<.Speed {fmt.eprintln("Build this benchmark with -o:speed.");os.exit(2)}
	output:="build/particle-worker-benchmark.json"
	boundary_only:=false
	large_3d_only:=false
	for argument in os.args[1:] {
		if argument=="--boundary" {boundary_only=true;continue}
		if argument=="--large-3d" {large_3d_only=true;continue}
		if !strings.has_prefix(argument,"--out=") {fmt.eprintln("Usage: particle_worker_benchmark [--boundary | --large-3d] [--out=report.json]");os.exit(2)}
		output=argument[len("--out="):]
	}
	ensure(output!="","The output path must not be empty.")
	if boundary_only && large_3d_only {fmt.eprintln("Choose only one case selection.");os.exit(2)}
	arena:mem.Dynamic_Arena;mem.dynamic_arena_init(&arena);defer mem.dynamic_arena_destroy(&arena)
	a:=mem.dynamic_arena_allocator(&arena)
	pools:=[3]^jobs.Pool{nil,jobs.create(1,64),jobs.create(3,64)}
	ensure(pools[1]!=nil && pools[2]!=nil,"Could not create worker pools.")
	defer jobs.destroy(pools[1]);defer jobs.destroy(pools[2])
	report:=Report{format_version=1,fixture="seeded-particle-cpu-v1",clock="core:time monotonic tick",os=ODIN_OS_STRING,arch=ODIN_ARCH_STRING,
		selection="large_3d" if large_3d_only else ("boundary" if boundary_only else "all"),pooled_thresholds_bypassed=true,
		compiler=ODIN_VERSION,compiler_hash=ODIN_VERSION_HASH,optimization=fmt.aprintf("%v",ODIN_OPTIMIZATION_MODE,allocator=a),
		microarch=ODIN_MICROARCH_STRING,cpu_description=cpu_description(a),warmup_rounds=Warmup_Rounds,measured_rounds=Measured_Rounds,
		production_min_work_2d=particles.Particle_Parallel_Min_Work_2D,production_min_count_3d=particles.Particle_Parallel_Min_Count_3D,
		production_billboard_min=bridge.Particle_Billboard_Parallel_Min,range_size_3d=particles.Update_3D_Range_Size,billboard_chunk_size=bridge.Particle_Billboard_Chunk_Size,
		iterations_per_sample=Iterations_Per_Sample,worker_counts=Worker_Counts,correctness_passed=true,results=make([dynamic]Result,a)}
	report.worker_execution_2d_passed=verify_2d_workers(pools[2])
	report.worker_execution_3d_passed=verify_3d_workers(pools[2])
	report.worker_execution_billboards_passed=verify_billboard_workers(pools[2])
	report.worker_execution_passed=report.worker_execution_2d_passed && report.worker_execution_3d_passed && report.worker_execution_billboards_passed
	report.correctness_passed=report.worker_execution_passed
	fmt.printf("Distinct non-owner worker IDs, overlapping work and exact results: 2D=%t 3D=%t billboards=%t\n",
		report.worker_execution_2d_passed,report.worker_execution_3d_passed,report.worker_execution_billboards_passed)
	fmt.println("stage blend batches x particles | serial_ms 1worker_ms 3workers_ms | speedup1 speedup3 | exact")
	if large_3d_only {
		for count in ([3]int{131072,262144,524288}) {record(&report,run_3d(count,pools,a))}
	} else if boundary_only {
		for fixture in ([2][2]int{{64,1024},{96,1024}}) {record(&report,run_2d(fixture[0],fixture[1],pools,a))}
		record(&report,run_3d(98304,pools,a))
		for blend in bridge.Particle3D_Blend {
			record(&report,run_billboards(16384,1,blend,pools,a))
			record(&report,run_billboards(8192,8,blend,pools,a))
		}
	} else {
		for fixture in ([10][2]int{{1,256},{8,256},{4,1024},{16,256},{8,1024},{16,1024},{32,1024},{64,1024},{96,1024},{128,1024}}) {record(&report,run_2d(fixture[0],fixture[1],pools,a))}
		for count in ([7]int{2048,8192,16384,32768,65536,98304,131072}) {record(&report,run_3d(count,pools,a))}
		for blend in bridge.Particle3D_Blend {
			for count in ([6]int{2048,4096,8192,16384,32768,131072}) {record(&report,run_billboards(count,1,blend,pools,a))}
			for count in ([3]int{8192,32768,131072}) {record(&report,run_billboards(count,8,blend,pools,a))}
		}
	}
	parent:=filepath.dir(output)
	if parent!="" {ensure(os.make_directory(parent)==nil || os.is_dir(parent),"Could not create the report directory.")}
	encoded,err:=json.marshal(report,{pretty=true,use_spaces=true},allocator=a)
	ensure(err==nil,"Could not encode the benchmark report.")
	ensure(os.write_entire_file(output,encoded)==nil,"Could not write the benchmark report.")
	fmt.printf("Report: %s (correctness=%t, worker_execution=%t)\n",output,report.correctness_passed,report.worker_execution_passed)
	if !report.correctness_passed {os.exit(1)}
}
