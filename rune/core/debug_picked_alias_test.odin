package core

import "core:fmt"
import "core:mem"
import "core:testing"
import "rune:console"
import "rune:ecs"

debug_picked_test_setup :: proc(engine: ^Engine, world: ^ecs.World) -> ecs.Entity {
	engine.registry = ecs.init_registry()
	assert(ecs.register_builtin_components(&engine.registry))
	engine.console = console.init()
	register_debug_commands(&engine.console)
	bind_debug_console(engine, world)
	engine.console.is_open = true
	debug_pick_test_camera_2d(world, &engine.registry)
	entity := debug_pick_test_shape(world, &engine.registry, "selected", {500,700})
	assert(debug_pick_scene(engine, {500,700}, {1000,1000}, {1000,1000}))
	return entity
}

debug_picked_test_has_completion :: proc(dev: ^console.Console, text, candidate: string) -> bool {
	console.edit(dev, .Select_All)
	assert(console.insert_text(dev, text))
	for option in console.completion_matches(dev).options {
		if option.value == candidate {return true}
	}
	return false
}

@(test)
debug_picked_alias_inspects_edits_and_changes_activation_of_the_live_pick :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena); defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	world := ecs.init(); defer ecs.destroy(&world)
	engine: Engine
	entity := debug_picked_test_setup(&engine, &world)
	defer ecs.destroy_registry(&engine.registry)
	dev := &engine.console
	errors := dev.error_count
	assert(console.execute(dev, "inspect @picked Transform"))
	testing.expect(t, debug_pick_test_result_id(dev) == "selected")
	assert(console.execute(dev, "set @picked Transform.position.0 123"))
	pose, found := ecs.get_transform(&world, entity)
	testing.expect(t, found && pose.position == {123,700,0} && debug_pick_test_result_id(dev) == "selected")
	assert(console.execute(dev, "enable @picked"))
	testing.expect(t, ecs.is_enabled(&world, entity))
	assert(console.execute(dev, "disable @picked"))
	testing.expect(t, !ecs.is_locally_enabled(&world, entity) && dev.error_count == errors)
	// Rendering multiple disabled frames must retain the same generation-bound
	// selection so the next command and its suggestions can still resolve it.
	for _ in 0..<3 {
		_, visible := debug_selection_bounds(&engine, {1000,1000}, {1000,1000})
		picked, valid := debug_picked_entity(&engine)
		testing.expect(t, !visible && valid && picked == entity)
	}
	testing.expect(t, debug_picked_test_has_completion(dev, "enable @p", "@picked"))
	assert(console.execute(dev, "inspect @picked Transform"))
	testing.expect(t, debug_pick_test_result_id(dev) == "selected")
	assert(console.execute(dev, "set @picked Transform.position.0 150"))
	assert(console.execute(dev, "enable @picked"))
	pose, found = ecs.get_transform(&world, entity)
	_, visible := debug_selection_bounds(&engine, {1000,1000}, {1000,1000})
	testing.expect(t, found && pose.position[0] == 150 && ecs.is_enabled(&world, entity) && visible && dev.error_count == errors,
		"enable @picked restores the same object and its highlight after disabled frames")
}

@(test)
debug_picked_alias_rejects_missing_closed_deleted_and_reloaded_selections :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena); defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	for invalid in 0..<5 {
		world := ecs.init(); defer ecs.destroy(&world)
		engine: Engine
		entity := debug_picked_test_setup(&engine, &world)
		defer ecs.destroy_registry(&engine.registry)
		switch invalid {
		case 0: clear_debug_selection(&engine)
		case 1: engine.console.is_open = false
		case 2: assert(ecs.destroy_entity(&world, entity))
		case 3:
			ecs.destroy(&world); world = ecs.init()
			// Same address and scene ID cannot revive a handle from the prior
			// World, even before another frame invalidates the overlay.
			debug_pick_test_shape(&world, &engine.registry, "selected", {500,700})
		case 4: bind_debug_console(&engine, nil)
		}
		_, found := debug_picked_entity(&engine)
		testing.expect(t, !found)
		before := engine.console.log_sequence
		errors := engine.console.error_count
		if invalid == 4 {engine.debug.world = &world} // Clear handle, valid command binding.
		assert(console.execute(&engine.console, "inspect @picked"))
		testing.expect(t, engine.console.error_count == errors + 1)
		logs := console.read_logs(&engine.console, before).entries
		testing.expect(t, len(logs) > 0 && logs[len(logs)-1].message == "No object is currently picked.")
	}
	_, found := debug_picked_entity(nil)
	testing.expect(t, !found)
}

@(test)
debug_picked_alias_survives_a_disabled_ancestor_without_changing_activation_rules :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena); defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	world := ecs.init(); defer ecs.destroy(&world)
	engine: Engine
	entity := debug_picked_test_setup(&engine, &world)
	defer ecs.destroy_registry(&engine.registry)
	parent := ecs.create_entity(&world)
	assert(ecs.set_parent(&world, entity, parent)); assert(ecs.set_enabled(&world, parent, false))
	_, visible := debug_selection_bounds(&engine, {1000,1000}, {1000,1000})
	picked, valid := debug_picked_entity(&engine)
	testing.expect(t, !visible && valid && picked == entity)
	errors := engine.console.error_count
	assert(console.execute(&engine.console, "disable @picked"))
	assert(console.execute(&engine.console, "enable @picked"))
	testing.expect(t, engine.console.error_count == errors && ecs.is_locally_enabled(&world, entity) && !ecs.is_enabled(&world, entity),
		"enabling the picked child keeps its disabled ancestor unchanged")
	assert(ecs.set_enabled(&world, parent, true))
	_, visible = debug_selection_bounds(&engine, {1000,1000}, {1000,1000})
	testing.expect(t, visible && engine.debug.picked_entity == entity)
}

@(test)
debug_picked_alias_is_reserved_before_literal_ids_and_keeps_an_unambiguous_handle_completion :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena); defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	world := ecs.init(); defer ecs.destroy(&world)
	engine: Engine
	selected := debug_picked_test_setup(&engine, &world)
	defer ecs.destroy_registry(&engine.registry)
	literal := debug_pick_test_shape(&world, &engine.registry, "@picked", {100,700})
	assert(console.execute(&engine.console, "inspect @picked"))
	testing.expect(t, debug_pick_test_result_id(&engine.console) == "selected")
	handle := fmt.tprintf("@%d", u64(literal))
	testing.expect(t, debug_picked_test_has_completion(&engine.console, "inspect @", handle))
	assert(console.execute(&engine.console, fmt.tprintf("inspect %s", handle)))
	testing.expect(t, debug_pick_test_result_id(&engine.console) == "@picked")
	clear_debug_selection(&engine)
	testing.expect(t, !debug_picked_test_has_completion(&engine.console, "inspect @", "@picked"))
	errors := engine.console.error_count
	assert(console.execute(&engine.console, "set @picked Transform.position.0 9"))
	pose, _ := ecs.get_transform(&world, literal)
	selected_pose, _ := ecs.get_transform(&world, selected)
	testing.expect(t, engine.console.error_count == errors + 1 && pose.position[0] == 100 && selected_pose.position[0] == 500,
		"missing selection never falls back to the literal scene ID @picked")
}

@(test)
debug_picked_alias_completes_entities_components_and_live_field_paths_without_output :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena); defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	world := ecs.init(); defer ecs.destroy(&world)
	engine: Engine
	entity := debug_picked_test_setup(&engine, &world)
	defer ecs.destroy_registry(&engine.registry)
	dev := &engine.console
	sequence, errors := dev.log_sequence, dev.error_count
	for command in ([]string{"inspect", "enable", "disable", "set"}) {
		testing.expect(t, debug_picked_test_has_completion(dev, fmt.tprintf("%s @p", command), "@picked"))
	}
	testing.expect(t, debug_picked_test_has_completion(dev, "inspect @picked T", "Transform"))
	testing.expect(t, debug_picked_test_has_completion(dev, "set @picked Transform.pos", "Transform.position"))
	testing.expect(t, debug_picked_test_has_completion(dev, "set @picked Transform.position.", "Transform.position.0"))
	assert(ecs.remove_component(&world, entity, "ShapeRenderer2D"))
	testing.expect(t, !debug_picked_test_has_completion(dev, "inspect @picked Shape", "ShapeRenderer2D"))
	assert(ecs.set_enabled(&world, entity, false))
	testing.expect(t, debug_picked_test_has_completion(dev, "inspect @p", "@picked"))
	testing.expect(t, debug_picked_test_has_completion(dev, "inspect @picked T", "Transform"))
	testing.expect(t, debug_picked_test_has_completion(dev, "set @picked Transform.", "Transform.position"))
	testing.expect(t, dev.log_sequence == sequence && dev.error_count == errors,
		"refreshing candidates borrows live data without writing logs or errors")
}

@(test)
debug_picked_alias_navmesh_filter_retains_the_resolved_named_or_unnamed_entity :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena); defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	world := ecs.init(); defer ecs.destroy(&world)
	engine: Engine
	entity := debug_picked_test_setup(&engine, &world)
	defer ecs.destroy_registry(&engine.registry)
	defer delete(engine.debug.navmesh_entity)
	dev := &engine.console
	testing.expect(t, !debug_picked_test_has_completion(dev, "navmesh on @p", "@picked"))
	assert(ecs.add(&world, &engine.registry, entity, ecs.NavMesh3D{asset="course.navmesh.json"}))
	testing.expect(t, debug_picked_test_has_completion(dev, "navmesh on @p", "@picked"))
	assert(console.execute(dev, "navmesh on @picked"))
	testing.expect(t, engine.gizmos.navmeshes && engine.gizmos.navmesh_entity == "selected" && engine.gizmos.navmesh_runtime_entity == 0)
	assert(ecs.set_entity_metadata(&world, entity, "", "", "", ecs.Default_Layer_Mask))
	assert(console.execute(dev, "navmesh on @picked"))
	testing.expect(t, engine.gizmos.navmesh_entity == fmt.tprintf("@%d", u64(entity)) && engine.gizmos.navmesh_runtime_entity == entity)
	filter := engine.gizmos.navmesh_entity
	clear_debug_selection(&engine)
	testing.expect(t, engine.gizmos.navmesh_entity == filter,
		"navigation visualization retains a concrete filter rather than redirecting to later selections")
	assert(console.execute(dev, "navmesh on"))
	testing.expect(t, engine.gizmos.navmesh_runtime_entity == 0 && engine.gizmos.navmesh_entity == "")
}
