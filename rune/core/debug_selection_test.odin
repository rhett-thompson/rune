package core

import "core:mem"
import "core:testing"
import "rune:console"
import "rune:ecs"
import rl "vendor:raylib"

debug_selection_expect_rectangle :: proc(t: ^testing.T, actual, expected: rl.Rectangle) {
	testing.expect(t,abs(actual.x-expected.x)<0.01 && abs(actual.y-expected.y)<0.01 &&
		abs(actual.width-expected.width)<0.01 && abs(actual.height-expected.height)<0.01)
}

@(test)
debug_selection_follows_live_bounds_camera_and_canvas_without_changing_inspection :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena); defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	world := ecs.init(); defer ecs.destroy(&world)
	registry := ecs.init_registry(); defer ecs.destroy_registry(&registry); assert(ecs.register_builtin_components(&registry))
	camera := debug_pick_test_camera_2d(&world,&registry)
	entity := debug_pick_test_shape(&world,&registry,"selected",{250,350})
	shape,_ := ecs.get_shape_renderer_2d(&world,entity); shape.origin={0,0}; assert(ecs.set_shape_renderer_2d(&world,entity,shape))
	engine := Engine{console=console.init()}; bind_debug_console(&engine,&world); engine.console.is_open=true
	engine.project.render_2d={policy=.fit,width=500,height=500}
	assert(debug_pick_scene(&engine,{550,600},{1000,800},{2000,1600}))
	testing.expect(t,engine.debug.picked_entity==entity && engine.debug.picked_dimension==.Two_D)
	sequence := engine.console.log_sequence
	inspected_id := debug_pick_test_result_id(&engine.console)
	bounds,visible := debug_selection_bounds(&engine,{1000,800},{2000,1600})
	testing.expect(t,visible)
	debug_selection_expect_rectangle(t,bounds,{500,560,128,128})
	pose,_ := ecs.get_transform(&world,entity); pose.position[0]+=10; assert(ecs.set_transform(&world,entity,pose))
	camera_pose,_ := ecs.get_transform(&world,camera); camera_pose.position[1]=20; assert(ecs.set_transform(&world,camera,camera_pose))
	bounds,visible=debug_selection_bounds(&engine,{1000,800},{2000,1600})
	testing.expect(t,visible)
	debug_selection_expect_rectangle(t,bounds,{516,528,128,128})
	testing.expect(t,engine.console.log_sequence==sequence && debug_pick_test_result_id(&engine.console)==inspected_id,"live highlighting does not re-run inspection or write console output")
	pose.position[0]=480; assert(ecs.set_transform(&world,entity,pose))
	bounds,visible=debug_selection_bounds(&engine,{1000,800},{2000,1600})
	testing.expect(t,visible)
	debug_selection_expect_rectangle(t,bounds,{868,528,32,128})
	pose.position[0]=600; assert(ecs.set_transform(&world,entity,pose))
	_,visible=debug_selection_bounds(&engine,{1000,800},{2000,1600})
	testing.expect(t,!visible && engine.debug.picked_entity==entity,"offscreen objects retain selection so it can reappear")
}

@(test)
debug_selection_clears_only_on_scene_miss_close_rebind_or_invalid_entity :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena); defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	world := ecs.init(); defer ecs.destroy(&world)
	registry := ecs.init_registry(); defer ecs.destroy_registry(&registry); assert(ecs.register_builtin_components(&registry))
	debug_pick_test_camera_2d(&world,&registry)
	entity := debug_pick_test_shape(&world,&registry,"selected",{500,700})
	engine := Engine{console=console.init()}; bind_debug_console(&engine,&world); engine.console.is_open=true
	assert(debug_pick_scene(&engine,{500,700},{1000,1000},{1000,1000}))
	assert(!debug_pick_scene(&engine,{500,200},{1000,1000},{1000,1000}))
	testing.expect(t,engine.debug.picked_entity==entity,"console panel clicks preserve the picked object")
	engine.console.defer_reply=true
	assert(!debug_pick_scene(&engine,{100,700},{1000,1000},{1000,1000}))
	testing.expect(t,engine.debug.picked_entity==entity,"pending commands keep selection unchanged")
	engine.console.defer_reply=false
	assert(!debug_pick_scene(&engine,{100,700},{1000,1000},{1000,1000}))
	testing.expect(t,engine.debug.picked_entity==0 && engine.debug.picked_dimension==.None,"an empty canvas click clears the marker")
	for invalid in 0..<3 {
		engine.console.is_open=true
		bind_debug_console(&engine,&world)
		engine.debug.picked_entity=entity; engine.debug.picked_dimension=.Two_D
		switch invalid {
		case 0: engine.console.is_open=false
		case 1: bind_debug_console(&engine,nil)
		case 2:
			ecs.destroy(&world); world=ecs.init() // Same address, a different generation.
		}
		_,visible:=debug_selection_bounds(&engine,{1000,1000},{1000,1000})
		testing.expect(t,!visible && engine.debug.picked_entity==0 && engine.debug.picked_dimension==.None)
	}
}
