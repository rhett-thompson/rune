package main

import "core:math"
import "core:mem"
import "rune:ecs"
import "rune:jobs"
import "rune:particles"

Emitters :: 4
Emitter_Particles :: max(4096,(particles.Particle_Parallel_Min_Work_2D+Emitters-1)/Emitters)
Simulation_Count_3D :: max(16384,particles.Particle_Parallel_Min_Count_3D)

emitter_world :: proc(registry:^ecs.Component_Registry,texture:string="") -> (ecs.World,[Emitters]ecs.Entity) {
	world:=ecs.init();entities:[Emitters]ecs.Entity
	assert(Emitter_Particles<=65536 && Emitter_Particles*Emitters>=particles.Particle_Parallel_Min_Work_2D)
	camera:=ecs.create_entity(&world)
	assert(ecs.add(&world,registry,camera,ecs.Transform{scale={1,1,1}}))
	assert(ecs.add(&world,registry,camera,ecs.Camera2D{active=true,zoom=1}))
	parent:=ecs.create_entity(&world)
	assert(ecs.add(&world,registry,parent,ecs.Transform{position={128,128,0},rotation={0,0,17},scale={1.1,0.9,1}}))
	for &entity,index in entities {
		entity=ecs.create_entity(&world);assert(ecs.set_parent(&world,entity,parent))
		assert(ecs.add(&world,registry,entity,ecs.Transform{position={f32(index-2)*34,0,0},scale={1,1,1}}))
		emitter:=ecs.default_particle_emitter_2d()
		emitter.max_particles=i32(Emitter_Particles);emitter.rate=600;emitter.emitting=false
		emitter.lifetime={0.12,1.2};emitter.speed={2,80};emitter.spread=360
		emitter.gravity={4,14};emitter.start_size=3;emitter.end_size=1
		emitter.start_color={u8(50+index*60),u8(240-index*50),160,90};emitter.end_color={10,40,220,0}
		emitter.seed=u32(index+17);emitter.additive=index%2==0;emitter.draw_order=i32(index)
		if index%2!=0 {emitter.texture=texture}
		assert(ecs.add(&world,registry,entity,emitter));assert(ecs.emit_particles_2d(&world,entity,Emitter_Particles)==Emitter_Particles)
	}
	return world,entities
}

compare_emitters :: proc(a,b:^ecs.World,ae,be:[Emitters]ecs.Entity) {
	for entity,index in ae {
		x,y:=a.particle_states_2d[entity],b.particle_states_2d[be[index]]
		assert(x.credit==y.credit && x.random==y.random && x.initialized==y.initialized && len(x.particles)==len(y.particles))
		for particle,j in x.particles {assert(particle==y.particles[j],"worker simulation preserves exact scalar order, motion, births and deaths")}
	}
}

Simulation_Busy :: struct {world:^ecs.World}
simulation_busy :: proc(pool:^jobs.Pool,data:rawptr) {ecs.update_particles_2d((^Simulation_Busy)(data).world,0.015,pool)}
Simulation_Busy_3D :: struct {state:^particles.Pool3D(Simulation_Count_3D)}
simulation_busy_3d :: proc(pool:^jobs.Pool,data:rawptr) {particles.update_3d((^Simulation_Busy_3D)(data).state,0.015,pool)}
copy_pool_3d :: proc(destination,source:^particles.Pool3D(Simulation_Count_3D)) {
	copy(destination.particles[:],source.particles[:]);destination.count=source.count;destination.random=source.random
}

validate_simulation :: proc(pool:^jobs.Pool) {
	registry:=ecs.init_registry();defer ecs.destroy_registry(&registry);assert(ecs.register_builtin_components(&registry))
	serial,se:=emitter_world(&registry);defer ecs.destroy(&serial)
	parallel,pe:=emitter_world(&registry);defer ecs.destroy(&parallel)
	for dt in ([8]f32{0.015,0.02,0.1,0,-1,math.nan_f32(),0.3,0.2}) {
		ecs.update_particles_2d(&serial,dt);ecs.update_particles_2d(&parallel,dt,pool);compare_emitters(&serial,&parallel,se,pe)
	}
	// Refill after expiry and enable births so owner-side reservations and RNG
	// are exercised along with the allocation-free integration/compaction jobs.
	for entity,index in se {
		a,_:=ecs.get_particle_emitter_2d(&serial,entity);a.emitting=true
		assert(ecs.set_particle_emitter_2d(&serial,entity,a));assert(ecs.set_particle_emitter_2d(&parallel,pe[index],a))
		assert(ecs.emit_particles_2d(&serial,entity,Emitter_Particles)==ecs.emit_particles_2d(&parallel,pe[index],Emitter_Particles))
	}
	for full in ([2]bool{false,true}) {
		for entity,index in se {assert(ecs.emit_particles_2d(&serial,entity,Emitter_Particles)==ecs.emit_particles_2d(&parallel,pe[index],Emitter_Particles))}
		ecs.update_particles_2d(&serial,0.015)
		data:=Simulation_Busy{world=&parallel};with_busy_pool(full,simulation_busy,&data)
		compare_emitters(&serial,&parallel,se,pe)
	}
	assert(ecs.set_enabled(&serial,se[1],false));assert(ecs.set_enabled(&parallel,pe[1],false))
	ecs.update_particles_2d(&serial,0.1);ecs.update_particles_2d(&parallel,0.1,pool);compare_emitters(&serial,&parallel,se,pe)
	assert(ecs.remove_component(&serial,se[2],"ParticleEmitter2D"));assert(ecs.remove_component(&parallel,pe[2],"ParticleEmitter2D"))
	ecs.update_particles_2d(&serial,0.1);ecs.update_particles_2d(&parallel,0.1,pool);compare_emitters(&serial,&parallel,se,pe)
	tracker:mem.Tracking_Allocator;mem.tracking_allocator_init(&tracker,context.allocator);defer mem.tracking_allocator_destroy(&tracker)
	{
		context.allocator=mem.tracking_allocator(&tracker)
		for _ in 0..<5 {ecs.update_particles_2d(&parallel,0.001,pool)}
	}
	assert(tracker.total_allocation_count==0,"warm 2D simulation makes no persistent owner allocation calls")
	serial3:=new(particles.Pool3D(Simulation_Count_3D));defer free(serial3)
	parallel3:=new(particles.Pool3D(Simulation_Count_3D));defer free(parallel3)
	settings:=particles.Burst3D{lifetime={0.03,2},speed={0.1,8},spread=360,gravity={1,-3,0.5},start_size=0.2,end_size=0.03,start_color={255,130,30,200},end_color={0,30,255,0},seed=131}
	assert(particles.emit_burst_3d(serial3,settings,Simulation_Count_3D,{1,2,3},{0,1,0})==Simulation_Count_3D)
	copy_pool_3d(parallel3,serial3)
	for dt in ([7]f32{0.016,0,-1,math.inf_f32(1),0.2,0.9,3}) {
		particles.update_3d(serial3,dt);particles.update_3d(parallel3,dt,pool)
		assert(serial3.count==parallel3.count && serial3.random==parallel3.random)
		for particle,index in serial3.particles[:serial3.count] {assert(particle==parallel3.particles[index],"3D integration and owner compaction preserve the scalar live prefix")}
	}
	particles.clear_3d(serial3);assert(particles.emit_burst_3d(serial3,settings,Simulation_Count_3D,{1,2,3},{0,1,0})==Simulation_Count_3D);copy_pool_3d(parallel3,serial3)
	for full in ([2]bool{false,true}) {
		particles.update_3d(serial3,0.015)
		busy:=Simulation_Busy_3D{parallel3};with_busy_pool(full,simulation_busy_3d,&busy)
		assert(serial3.count==parallel3.count)
		for particle,index in serial3.particles[:serial3.count] {assert(particle==parallel3.particles[index])}
	}
}
