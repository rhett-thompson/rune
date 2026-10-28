package ecs

import core_runtime "base:runtime"
import "core:mem"
import "core:slice"
import "rune:jobs"
import "rune:navigation"

// Dispatch overhead is avoided when fewer agents need a path this step.
Navigation_Parallel_Query_Minimum_3D :: 4

Navigation_Agent_Update_3D :: struct {
	entity: Entity,
	config: NavAgent3D,
	transform: Transform,
	runtime: Nav_Agent_Runtime_3D,
	mesh: Entity,
	mesh_revision, config_version: u64,
}

Navigation_Path_Work_3D :: struct {
	update_index: int,
	mesh: navigation.Mesh_3D,
	preparation: ^navigation.Clearance_Preparation_3D,
	start, goal: [3]f32,
	options: navigation.Path_Options_3D,
	path: navigation.Path_3D,
}

Navigation_Path_Batch_3D :: struct {
	requests: []Navigation_Path_Work_3D,
	result_allocator: mem.Allocator,
}

// Run before physics on each fixed step. Game systems may set targets first.
// A pool is borrowed only until return. All World access and movement stay on
// this thread; workers read stable geometry/preparation and write their own path.
update_navigation_3d :: proc(world: ^World, dt: f32, pool: ^jobs.Pool = nil) {
	if world == nil || !finite_nonnegative(dt) || dt <= 0 || len(world.navigation_3d.agents) == 0 {return}
	entities := make([]Entity, len(world.navigation_3d.agents), context.temp_allocator)
	entity_index := 0
	for entity in world.navigation_3d.agents {entities[entity_index] = entity; entity_index += 1}
	slice.sort(entities)
	updates := make([dynamic]Navigation_Agent_Update_3D, 0, len(entities), context.temp_allocator)
	requests := make([dynamic]Navigation_Path_Work_3D, 0, len(entities), context.temp_allocator)
	for entity in entities {
		runtime := world.navigation_3d.agents[entity]
		config, found := get(world, entity, NavAgent3D)
		if !found {continue}
		runtime.state.desired_velocity = {}
		runtime.state.actual_velocity = {}; runtime.state.remaining_distance = 0
		if config.drive_controller {character_controller_3d_move(world, entity, {})}
		if !runtime.state.has_target {world.navigation_3d.agents[entity] = runtime; continue}
		if !is_enabled(world, entity) {
			runtime.state.status = .Disabled; runtime.revision = 0; runtime.current_speed = 0; runtime.position_valid = false
			world.navigation_3d.agents[entity] = runtime; continue
		}
		transform, has_transform := get_transform(world, entity)
		mesh_entity, has_mesh := resolve_entity_ref(world, config.mesh)
		mesh, mesh_ready := navigation_mesh_3d(world, mesh_entity)
		parent, has_parent := get_parent(world, entity)
		if !has_transform || !has_mesh || !mesh_ready || has_parent || parent != Entity(0) || transform.scale != ([3]f32{1,1,1}) ||
		   has_component_data(world, entity, "RigidBody3D") || (!config.drive_controller && has_component_data(world, entity, "CharacterController3D")) {
			runtime.state.status = .Unavailable; runtime.revision = 0; runtime.current_speed = 0; runtime.position_valid = false
			world.navigation_3d.agents[entity] = runtime; continue
		}
		if config.drive_controller {
			motor, ok := get_character_controller_3d(world, entity)
			if !ok || !character_controller_3d_ready(world, entity) || config.radius < motor.radius || config.height < motor.height || config.max_slope > motor.max_slope_angle {
				runtime.state.status = .Unavailable; runtime.revision = 0; runtime.current_speed = 0; runtime.position_valid = false
				world.navigation_3d.agents[entity] = runtime; continue
			}
		}
		mesh_revision := world.navigation_3d.meshes[mesh_entity].revision
		// Motors legitimately travel between navigation updates. Other movement
		// is a teleport and must invalidate the old corridor immediately.
		teleport_distance := max(config.max_projection, config.speed*dt*4+0.25) if config.drive_controller else f32(0.001)
		if runtime.position_valid {
			if navigation.distance_3d(runtime.last_position, transform.position) > teleport_distance {
				runtime.revision = 0; runtime.current_speed = 0
			} else if config.drive_controller {
				runtime.state.actual_velocity = (transform.position-runtime.last_position)/dt
			}
		}
		runtime.last_position = transform.position; runtime.position_valid = true
		config_version := world.component_changes[Component_Change_Key{entity=entity, name="NavAgent3D"}].version
		runtime.repath_remaining -= dt
		update_index := len(updates)
		append(&updates, Navigation_Agent_Update_3D{entity, config, transform, runtime, mesh_entity, mesh_revision, config_version})
		if runtime.repath_remaining <= 0 || runtime.revision != mesh_revision || runtime.mesh != mesh_entity || runtime.config_version != config_version {
			options := navigation.Path_Options_3D{radius=config.radius, height=config.height, max_slope=config.max_slope, max_projection=config.max_projection}
			// Populate the lazy, bounded cache before any worker borrows it.
			preparation := navigation_clearance_preparation_3d(world, mesh_entity, &mesh, transform.position, options)
			append(&requests, Navigation_Path_Work_3D{update_index=update_index, mesh=mesh, preparation=preparation,
				start=transform.position, goal=runtime.state.target, options=options})
		}
	}
	parallel := pool != nil && len(requests) >= Navigation_Parallel_Query_Minimum_3D
	batch := Navigation_Path_Batch_3D{requests=requests[:], result_allocator=context.allocator}
	if parallel {
		// The caller's allocator may be a non-thread-safe arena. Only final
		// path buffers cross the barrier; rehome them on the owner thread below.
		batch.result_allocator = core_runtime.default_context().allocator
		jobs.parallel_for(pool, len(requests), navigation_query_job_3d, &batch)
	} else {
		for index in 0..<len(requests) {navigation_query_job_3d(index, &batch)}
	}
	// No worker can retain borrowed mesh arrays or preparations beyond here.
	for &request in requests {
		update := &updates[request.update_index]
		runtime := &update.runtime
		navigation.destroy_path_3d(&runtime.path)
		runtime.path = navigation_take_job_path_3d(&request.path, parallel, batch.result_allocator)
		runtime.state.path = runtime.path.points; runtime.state.path_status = runtime.path.status; runtime.state.next_point = 0
		if update.config.drive_controller && runtime.path.status == .Complete {runtime.state.next_point = 1}
		runtime.repath_remaining = update.config.repath_interval; runtime.revision = update.mesh_revision
		runtime.mesh = update.mesh; runtime.config_version = update.config_version
	}
	for &update in updates {
		navigation_advance_agent_3d(world, update.entity, &update.runtime, update.config, update.transform, dt)
		world.navigation_3d.agents[update.entity] = update.runtime
	}
}

navigation_query_job_3d :: proc(index: int, data: rawptr) {
	batch := (^Navigation_Path_Batch_3D)(data)
	request := &batch.requests[index]
	request.path = navigation.find_path_3d(&request.mesh, request.start, request.goal, request.options, batch.result_allocator, request.preparation)
}

navigation_take_job_path_3d :: proc(source: ^navigation.Path_3D, rehome: bool, allocator: mem.Allocator) -> navigation.Path_3D {
	path := source^
	if rehome {
		path.points = make([][3]f32, len(source.points))
		path.triangles = make([]i32, len(source.triangles))
		copy(path.points, source.points); copy(path.triangles, source.triangles)
		delete(source.points, allocator); delete(source.triangles, allocator)
	}
	source^ = {}
	return path
}
