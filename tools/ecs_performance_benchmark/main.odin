// CPU-only mass expiry and disjoint character-trigger scaling fixtures.
package main

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:time"
import "rune:ecs"

milliseconds :: proc(start:time.Tick) -> f64 {
	return time.duration_seconds(time.tick_since(start))*1000
}

lifetime_case :: proc(registry:^ecs.Component_Registry,count:int,persistent:int=0) {
	values:[3]f64
	for &value in values {
		world:=ecs.init()
		for _ in 0..<count {
			entity:=ecs.create_entity(&world)
			assert(ecs.add(&world,registry,entity,ecs.Lifetime{seconds=1}))
		}
		for _ in 0..<persistent {_ = ecs.create_entity(&world)}
		_ = ecs.root_entities(&world)
		version:=world.hierarchy_version
		baseline_started:=time.tick_now()
		ecs.update_lifetimes(&world,0.01)
		baseline_ms:=milliseconds(baseline_started)
		started:=time.tick_now()
		ecs.update_lifetimes(&world,1)
		value=milliseconds(started)
		assert(world.entity_count==persistent)
		fmt.printf("lifetime n=%d persistent=%d ms=%.4f no_expiration_ms=%.4f hierarchy_rebuilds=%d\n",count,persistent,value,baseline_ms,world.hierarchy_version-version)
		ecs.destroy(&world)
		free_all(context.temp_allocator)
	}
	slice.sort(values[:])
	fmt.printf("lifetime n=%d persistent=%d median_ms=%.4f\n",count,persistent,values[1])
}

trigger_case :: proc(registry:^ecs.Component_Registry,triggers,actors:int) {
	world:=ecs.init()
	defer ecs.destroy(&world)
	for i in 0..<triggers {
		entity:=ecs.create_entity(&world)
		pose:=ecs.default_transform();pose.position={f32(i)*4,0,0}
		assert(ecs.add(&world,registry,entity,pose))
		assert(ecs.add(&world,registry,entity,ecs.Default_Trigger_3D))
	}
	for i in 0..<actors {
		entity:=ecs.create_entity(&world)
		pose:=ecs.default_transform();pose.position={f32(i)*4,0,10000}
		assert(ecs.add(&world,registry,entity,pose))
		assert(ecs.add(&world,registry,entity,ecs.default_character_controller_3d()))
	}
	for _ in 0..<3 {ecs.update_triggers_3d(&world);free_all(context.temp_allocator)}
	values:[9]f64
	for &value in values {
		started:=time.tick_now()
		ecs.update_triggers_3d(&world)
		value=milliseconds(started)
		assert(len(ecs.trigger_events_3d(&world))==0)
		free_all(context.temp_allocator)
	}
	slice.sort(values[:])
	fmt.printf("triggers=%d actors=%d all_disjoint median_ms=%.4f max_ms=%.4f\n",triggers,actors,values[4],values[8])
}

main :: proc() {
	assert(ODIN_OPTIMIZATION_MODE==.Speed)
	fmt.printf("ECS CPU benchmark: %s/%s Odin %s:%s %v %s\n",ODIN_OS_STRING,ODIN_ARCH_STRING,ODIN_VERSION,ODIN_VERSION_HASH,ODIN_OPTIMIZATION_MODE,ODIN_MICROARCH_STRING)
	registry:=ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	arena:mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator=mem.dynamic_arena_allocator(&arena)
	for count in ([4]int{250,500,1000,2000}) {lifetime_case(&registry,count)}
	lifetime_case(&registry,250,5000)
	lifetime_case(&registry,1000,10000)
	trigger_case(&registry,100,1)
	trigger_case(&registry,100,100)
	trigger_case(&registry,500,100)
	trigger_case(&registry,500,500)
	trigger_case(&registry,1000,1000)
	fmt.println("ECS performance benchmark passed")
}
