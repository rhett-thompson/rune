package core

import "core:encoding/json"
import "core:mem"
import "core:testing"
import "rune:console"
import "rune:ecs"
import rl "vendor:raylib"

debug_pick_test_camera_2d :: proc(world: ^ecs.World, registry: ^ecs.Component_Registry) -> ecs.Entity {
	camera := ecs.create_entity(world)
	assert(ecs.add(world, registry, camera, ecs.default_transform()))
	value := ecs.default_camera_2d(); value.active = true
	assert(ecs.add(world, registry, camera, value))
	return camera
}

debug_pick_test_shape :: proc(world: ^ecs.World, registry: ^ecs.Component_Registry, id: string, position: [2]f32) -> ecs.Entity {
	entity := ecs.create_entity(world)
	assert(ecs.set_entity_metadata(world, entity, id, "Picked object", "", ecs.Default_Layer_Mask))
	assert(ecs.add(world, registry, entity, ecs.Transform{position={position[0], position[1], 0}, scale={1,1,1}}))
	shape := ecs.default_shape_renderer_2d(); shape.size = {80,80}
	assert(ecs.add(world, registry, entity, shape))
	return entity
}

debug_pick_test_result_id :: proc(dev: ^console.Console) -> string {
	object, valid := dev.result_data.(json.Object); if !valid {return ""}
	entity, has_entity := object["entity"].(json.Object); if !has_entity {return ""}
	id, has_id := entity["id"].(json.String); if !has_id {return ""}
	return string(id)
}

debug_pick_test_unchanged :: proc(t: ^testing.T, dev, before: ^console.Console) {
	testing.expect(t, dev.log_sequence == before.log_sequence && dev.line_count == before.line_count && dev.error_count == before.error_count,
		"a guarded click cannot contaminate pending command logs or errors")
	result, valid := dev.result_data.(json.Integer)
	testing.expect(t, valid && result == 42, "a guarded click preserves the current command result")
	testing.expect(t, dev.input == before.input && dev.input_len == before.input_len && dev.input_caret == before.input_caret && dev.input_anchor == before.input_anchor)
	testing.expect(t, dev.history == before.history && dev.history_count == before.history_count && dev.history_index == before.history_index)
	testing.expect(t, dev.history_draft == before.history_draft && dev.history_draft_len == before.history_draft_len && dev.history_draft_caret == before.history_draft_caret)
}

@(test)
debug_picking_guards_preserve_pending_results_logs_and_drafts :: proc(t: ^testing.T) {
	world := ecs.init(); defer ecs.destroy(&world)
	registry := ecs.init_registry(); defer ecs.destroy_registry(&registry); assert(ecs.register_builtin_components(&registry))
	debug_pick_test_camera_2d(&world, &registry)
	debug_pick_test_shape(&world, &registry, "box", {500,700})
	engine := Engine{console=console.init()}
	bind_debug_console(&engine, &world)
	engine.console.is_open = true
	assert(console.execute(&engine.console, "clear"))
	assert(console.insert_text(&engine.console, "unfinished command"))
	console.edit(&engine.console, .Previous_History)
	console.set_input_caret(&engine.console, 2)
	engine.console.result_data = json.Integer(42)
	before := engine.console
	for guard in 0..<7 {
		engine.console.is_open = true
		engine.console.defer_reply = false
		engine.console.remote.result_len = 0
		engine.debug.world = &world
		point, screen := [2]f32{500,700}, [2]f32{1000,1000}
		switch guard {
		case 0: engine.console.is_open = false
		case 1: engine.debug.world = nil
		case 2: point = {500,200} // Console output and suggestion rows own this click.
		case 3: engine.console.defer_reply = true
		case 4: engine.console.remote.result_len = 1
		case 5: screen[0] = 0
		case 6: point[0] = transmute(f32)u32(0x7fc00000)
		}
		testing.expect(t, !debug_pick_scene(&engine, point, screen, {1000,1000}))
		debug_pick_test_unchanged(t, &engine.console, &before)
	}
	testing.expect(t, !debug_pick_scene(nil, {500,700}, {1000,1000}, {1000,1000}))
}

@(test)
debug_picking_inspects_current_components_and_preserves_command_history :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena); defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	world := ecs.init(); defer ecs.destroy(&world)
	registry := ecs.init_registry(); defer ecs.destroy_registry(&registry); assert(ecs.register_builtin_components(&registry))
	debug_pick_test_camera_2d(&world, &registry)
	entity := debug_pick_test_shape(&world, &registry, `box "two"`, {500,700})
	child := ecs.create_entity(&world); assert(ecs.set_parent(&world, child, entity))
	assert(ecs.set_entity_metadata(&world, child, "child", "", "", ecs.Default_Layer_Mask))
	shape, _ := ecs.get_shape_renderer_2d(&world, entity); shape.size = {100,110}; assert(ecs.set_shape_renderer_2d(&world, entity, shape))
	engine := Engine{console=console.init()}; bind_debug_console(&engine, &world); engine.console.is_open = true
	assert(console.execute(&engine.console, "clear"))
	assert(console.insert_text(&engine.console, "inspect unfinished"))
	console.set_input_caret(&engine.console, 3)
	before := engine.console
	engine.console.scroll_offset = 5; engine.console.scroll_anchor_sequence = 1; engine.console.scroll_anchor_byte = 3
	testing.expect(t, debug_pick_scene(&engine, {500,700}, {1000,1000}, {1000,1000}))
	testing.expect(t, debug_pick_test_result_id(&engine.console) == `box "two"`, "picking uses the entity directly even when its ID needs command quoting")
	result := engine.console.result_data.(json.Object)
	children := result["children"].(json.Array)
	testing.expect(t, len(children) == 1 && children[0].(json.String) == "child")
	components := result["components"].(json.Object)
	size := components["ShapeRenderer2D"].(json.Object)["size"].(json.Array)
	width, _ := ecs.read_number(size[0]); height, _ := ecs.read_number(size[1])
	testing.expect(t, width == 100 && height == 110, "inspection reads current typed component values")
	testing.expect(t, engine.console.input == before.input && engine.console.input_caret == before.input_caret && engine.console.input_anchor == before.input_anchor)
	testing.expect(t, engine.console.history == before.history && engine.console.history_count == before.history_count && engine.console.history_index == before.history_index)
	testing.expect(t, engine.console.scroll_offset == 0 && engine.console.scroll_anchor_sequence == 0, "the inspection follows the latest output")
	last := &engine.console.lines[(engine.console.line_start + engine.console.line_count - 1) % console.Max_Log_Lines]
	testing.expect(t, last.len >= 7 && string(last.text[:7]) == "Picked ")
}

@(test)
debug_picking_matches_local_2d_camera_transform_rotation_and_zoom :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena); defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	world := ecs.init(); defer ecs.destroy(&world)
	registry := ecs.init_registry(); defer ecs.destroy_registry(&registry); assert(ecs.register_builtin_components(&registry))
	camera := debug_pick_test_camera_2d(&world, &registry)
	parent := ecs.create_entity(&world); assert(ecs.add(&world,&registry,parent,ecs.Transform{position={10000,10000,0},scale={3,3,1}}))
	assert(ecs.set_parent(&world,camera,parent))
	pose := ecs.default_transform(); pose.position = {10,20,0}; assert(ecs.set_transform(&world,camera,pose))
	value, _ := ecs.get_camera_2d(&world,camera); value.offset={500,700}; value.rotation=37; value.zoom=2
	assert(ecs.set_camera_2d(&world,camera,value))
	debug_pick_test_shape(&world,&registry,"camera_target",{30,30})
	point := rl.GetWorldToScreen2D({30,30},rl.Camera2D{target={10,20},offset=value.offset,rotation=value.rotation,zoom=value.zoom})
	engine := Engine{console=console.init()}; bind_debug_console(&engine,&world); engine.console.is_open=true
	testing.expect(t, point.y>500 && debug_pick_scene(&engine,point,{1000,1000},{1000,1000}))
	testing.expect(t, debug_pick_test_result_id(&engine.console)=="camera_target", "2D picking matches the renderer's local camera target rather than inheriting its parent")
}

@(test)
debug_picking_converts_hidpi_canvas_and_rejects_letterbox_bars :: proc(t:^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena); defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator=mem.dynamic_arena_allocator(&arena)
	world:=ecs.init(); defer ecs.destroy(&world)
	registry:=ecs.init_registry(); defer ecs.destroy_registry(&registry); assert(ecs.register_builtin_components(&registry))
	debug_pick_test_camera_2d(&world,&registry)
	debug_pick_test_shape(&world,&registry,"canvas_object",{250,350})
	engine:=Engine{console=console.init()}; bind_debug_console(&engine,&world); engine.console.is_open=true
	engine.project.render_2d={policy=.fit,width=500,height=500}
	testing.expect(t,debug_pick_scene(&engine,{500,700},{1000,1000},{2000,2000}))
	testing.expect(t,debug_pick_test_result_id(&engine.console)=="canvas_object","logical pointer coordinates map to the reference canvas without applying DPI twice")
	// Under a 2:1 reference canvas, this lower bar maps to y=325. A shape
	// there would be selectable if the canvas's inside flag were ignored.
	debug_pick_test_shape(&world,&registry,"outside_canvas",{250,325})
	engine.project.render_2d={policy=.fit,width=500,height=250}
	engine.console.result_data=json.Integer(42)
	before:=engine.console
	testing.expect(t,!debug_pick_scene(&engine,{500,900},{1000,1000},{2000,2000}))
	debug_pick_test_unchanged(t,&engine.console,&before)
}

@(test)
debug_picking_prioritizes_3d_hierarchy_hits_then_falls_back_to_2d :: proc(t:^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena); defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator=mem.dynamic_arena_allocator(&arena)
	world:=ecs.init(); defer ecs.destroy(&world)
	registry:=ecs.init_registry(); defer ecs.destroy_registry(&registry); assert(ecs.register_builtin_components(&registry))
	debug_pick_test_camera_2d(&world,&registry)
	debug_pick_test_shape(&world,&registry,"flat_object",{500,700})
	parent:=ecs.create_entity(&world); assert(ecs.add(&world,&registry,parent,ecs.Transform{position={10,0,0},scale={1,1,1}}))
	camera:=ecs.create_entity(&world); assert(ecs.set_parent(&world,camera,parent)); assert(ecs.add(&world,&registry,camera,ecs.default_transform()))
	value:=ecs.default_camera_3d(); value.active=true; value.target={10,0,1}; value.fovy=90; assert(ecs.add(&world,&registry,camera,value))
	near:=ecs.create_entity(&world); assert(ecs.set_entity_metadata(&world,near,"near_cube","","",ecs.Default_Layer_Mask))
	assert(ecs.add(&world,&registry,near,ecs.Transform{position={10,-2,5},scale={2,2,1}})); assert(ecs.add(&world,&registry,near,ecs.MeshRenderer{primitive="cube"}))
	far:=ecs.create_entity(&world); assert(ecs.set_entity_metadata(&world,far,"far_cube","","",ecs.Default_Layer_Mask))
	assert(ecs.add(&world,&registry,far,ecs.Transform{position={10,-4,10},scale={2,2,1}})); assert(ecs.add(&world,&registry,far,ecs.MeshRenderer{primitive="cube"}))
	engine:=Engine{console=console.init()}; bind_debug_console(&engine,&world); engine.console.is_open=true
	testing.expect(t,debug_pick_scene(&engine,{500,700},{1000,1000},{1000,1000}))
	testing.expect(t,debug_pick_test_result_id(&engine.console)=="near_cube","nearest 3D surface wins over the 2D object, using the camera's composed world position")
	testing.expect(t,engine.debug.picked_entity==near && engine.debug.picked_dimension==.Three_D)
	assert(ecs.set_enabled(&world,near,false)); assert(ecs.set_enabled(&world,far,false))
	testing.expect(t,debug_pick_scene(&engine,{500,700},{1000,1000},{1000,1000}))
	testing.expect(t,debug_pick_test_result_id(&engine.console)=="flat_object","no supported 3D hit falls back to the active 2D scene")
	testing.expect(t,engine.debug.picked_dimension==.Two_D,"selection bounds must use the camera of the successful pick")
	assert(ecs.set_enabled(&world,near,true)); assert(ecs.remove_component(&world,camera,"Transform"))
	testing.expect(t,debug_pick_scene(&engine,{500,700},{1000,1000},{1000,1000}))
	testing.expect(t,debug_pick_test_result_id(&engine.console)=="flat_object",
		"a Camera3D without its own Transform cannot take priority because the 3D renderer declines that camera, even when its parent supplies an inherited pose")
}

@(test)
debug_picking_reacquires_entities_after_world_replacement :: proc(t:^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena); defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator=mem.dynamic_arena_allocator(&arena)
	world:=ecs.init(); defer ecs.destroy(&world)
	registry:=ecs.init_registry(); defer ecs.destroy_registry(&registry); assert(ecs.register_builtin_components(&registry))
	debug_pick_test_camera_2d(&world,&registry)
	previous:=debug_pick_test_shape(&world,&registry,"before_reload",{500,700})
	engine:=Engine{console=console.init()}; bind_debug_console(&engine,&world); engine.console.is_open=true
	testing.expect(t,debug_pick_scene(&engine,{500,700},{1000,1000},{1000,1000}))
	snapshot:=engine.console.result_data
	ecs.destroy(&world); world=ecs.init()
	debug_pick_test_camera_2d(&world,&registry)
	current:=debug_pick_test_shape(&world,&registry,"after_reload",{500,700})
	testing.expect(t,current!=previous && !ecs.is_alive(&world,previous))
	testing.expect(t,debug_pick_scene(&engine,{500,700},{1000,1000},{1000,1000}))
	testing.expect(t,debug_pick_test_result_id(&engine.console)=="after_reload","the next click queries the currently attached World without retaining the old entity handle")
	testing.expect(t,snapshot.(json.Object)["entity"].(json.Object)["id"].(json.String)=="before_reload",
		"inspection snapshots own strings independently of the replaced scene for the rest of the frame")
}

@(test)
debug_picking_camera_rays_clip_perspective_and_orthographic_views :: proc(t:^testing.T) {
	camera:=rl.Camera3D{position={0,0,0},target={0,0,1},up={0,1,0},fovy=90}
	origin,translation,valid:=debug_pick_camera_ray(camera,{1000,750},{2000,1000},1,10)
	testing.expect(t,valid && abs(origin[2]-1)<0.001 && abs(origin[1]+0.5)<0.001)
	end:=origin+translation
	testing.expect(t,abs(end[2]-10)<0.001 && abs(end[1]+5)<0.001,"perspective segment ends on the far clip plane rather than at a constant distance along an oblique ray")
	camera.projection=.ORTHOGRAPHIC; camera.fovy=8
	origin,translation,valid=debug_pick_camera_ray(camera,{1000,750},{2000,1000},1,10)
	testing.expect(t,valid && abs(origin[1]+2)<0.001 && abs(origin[2]-1)<0.001 && abs(translation[2]-9)<0.001)
	other_origin,other_translation,other_valid:=debug_pick_camera_ray(camera,{100,900},{2000,1000},1,10)
	testing.expect(t,other_valid && rl.Vector3Length(other_translation-translation)<0.001 && rl.Vector3Length(other_origin-origin)>1,"orthographic screen positions change the origin, keeping parallel rays")
	camera.position={4,5,6}; camera.target={5,5,6}; camera.up={0,1,0}; camera.projection=.PERSPECTIVE
	origin,translation,valid=debug_pick_camera_ray(camera,{1000,500},{2000,1000},1,10)
	testing.expect(t,valid && rl.Vector3Length(origin-[3]f32{5,5,6})<0.001 && rl.Vector3Length(translation-[3]f32{9,0,0})<0.001,"ray follows an arbitrary camera orientation")
}

@(test)
debug_picking_camera_rays_reject_degenerate_views_and_clip_ranges :: proc(t:^testing.T) {
	base:=rl.Camera3D{target={0,0,1},up={0,1,0},fovy=45}
	for invalid in 0..<8 {
		camera:=base; viewport:=[2]f32{1000,1000}; near,far:=f32(0.01),f32(1000)
		switch invalid {
		case 0: camera.target=camera.position
		case 1: camera.up={0,0,1}
		case 2: camera.fovy=0
		case 3: camera.fovy=180
		case 4: viewport[0]=0
		case 5: near=-1
		case 6: far=near
		case 7: camera.position[0]=transmute(f32)u32(0x7f800000)
		}
		_,_,valid:=debug_pick_camera_ray(camera,{500,700},viewport,near,far)
		testing.expect(t,!valid,"degenerate camera or clip ranges do not produce a picking segment")
	}
}
