package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import rune "rune:core"
import "rune:ecs"
import b2 "vendor:box2d"
import b3 "vendor:box3d"

parse :: proc(text: string) -> json.Value {
	value: json.Value
	assert(
		json.unmarshal(transmute([]u8)text, &value, allocator = context.temp_allocator) == nil,
		text,
	)
	return value
}

add :: proc(
	world: ^ecs.World,
	registry: ^ecs.Component_Registry,
	entity: ecs.Entity,
	name, text: string,
) {
	assert(ecs.add_component(world, registry, entity, name, parse(text)), name)
}

box_name :: proc(d: int) -> string {return "BoxCollider2D" if d == 2 else "BoxCollider"}
round_name :: proc(d: int) -> string {return "CircleCollider2D" if d == 2 else "SphereCollider"}

body :: proc(
	world: ^ecs.World,
	registry: ^ecs.Component_Registry,
	d: int,
	x: f32,
	sensor, moving: bool,
	layers: u64 = 1,
	round := false,
) -> ecs.Entity {
	entity := ecs.create_entity(world)
	assert(
		ecs.set_entity_metadata(world, entity, fmt.tprintf("entity-%d", entity), "", "", layers),
	)
	add(world, registry, entity, "Transform", fmt.tprintf(`{{"position":[%f,0,0]}}`, x))
	name := box_name(d)
	data := fmt.tprintf(`{{"size":[2,2],"is_sensor":%t}}`, sensor)
	if d == 3 {data = fmt.tprintf(`{{"size":[2,2,2],"is_sensor":%t}}`, sensor)}
	if round {
		name = round_name(d)
		data = fmt.tprintf(`{{"radius":1,"is_sensor":%t}}`, sensor)
	}
	add(world, registry, entity, name, data)
	if moving {
		name = "RigidBody2D" if d == 2 else "RigidBody3D"
		add(world, registry, entity, name, `{"gravity_scale":0}`)
	}
	return entity
}

step :: proc(world: ^ecs.World, d: int, count := 1) {
	for _ in 0 ..< count {
		if d ==
		   2 {ecs.physics_2d_update(world, ecs.Physics2D_Fixed_Delta)} else {ecs.physics_3d_update(world, ecs.Physics3D_Fixed_Delta)}
	}
}

events :: proc(world: ^ecs.World, d: int) -> []ecs.Physics_Event {
	return ecs.physics_2d_events(world) if d == 2 else ecs.physics_3d_events(world)
}

ray :: proc(
	world: ^ecs.World,
	d: int,
	filter := ecs.Default_Physics_Query_Filter,
) -> (
	ecs.Entity,
	f32,
	bool,
) {
	if d == 2 {
		hit, ok := ecs.physics_2d_raycast(world, {0, 0}, {20, 0}, filter)
		if ok {assert(math.abs(hit.point[0] - hit.fraction * 20) < 0.001 && hit.normal[0] < -0.99)}
		return hit.entity, hit.fraction, ok
	}
	hit, ok := ecs.physics_3d_raycast(world, {0, 0, 0}, {20, 0, 0}, filter)
	if ok {assert(math.abs(hit.point[0] - hit.fraction * 20) < 0.001 && hit.normal[0] < -0.99)}
	return hit.entity, hit.fraction, ok
}

overlap :: proc(
	world: ^ecs.World,
	d: int,
	center: [3]f32,
	radius: f32,
	filter := ecs.Default_Physics_Query_Filter,
	box := false,
) -> []ecs.Entity {
	if d == 2 {
		if box {return ecs.physics_2d_overlap_box(world, {center[0], center[1]}, {radius, radius}, filter)}
		return ecs.physics_2d_overlap_circle(world, {center[0], center[1]}, radius, filter)
	}
	if box {return ecs.physics_3d_overlap_box(world, center, {radius, radius, radius}, filter)}
	return ecs.physics_3d_overlap_sphere(world, center, radius, filter)
}

move :: proc(world: ^ecs.World, entity: ecs.Entity, x: f32) {
	transform, ok := ecs.get_transform(world, entity)
	assert(ok)
	transform.position[0] = x
	assert(ecs.set_transform(world, entity, transform))
}

validate_queries :: proc(registry: ^ecs.Component_Registry, d: int) {
	world := ecs.init()
	defer ecs.destroy(&world)
	sensor := body(&world, registry, d, 5, true, false)
	wall := body(&world, registry, d, 10, false, false)
	ball := body(&world, registry, d, 15, false, false, round = true)
	other_layer := body(&world, registry, d, 2, false, false, layers = 2)
	filter := ecs.Default_Physics_Query_Filter
	filter.layers = 1
	entity, fraction, found := ray(&world, d, filter)
	assert(
		found && entity == sensor && math.abs(fraction - 0.2) < 0.001,
		"query before first step",
	)
	filter.include_sensors = false
	entity, fraction, found = ray(&world, d, filter)
	assert(found && entity == wall && math.abs(fraction - 0.45) < 0.001)
	filter.ignore = wall
	entity, _, found = ray(&world, d, filter)
	assert(found && entity == ball)
	filter.layers = 2
	entity, _, found = ray(&world, d, filter)
	assert(found && entity == other_layer)
	assert(ecs.set_entity_layer_mask(&world, other_layer, 4))
	_, _, found = ray(&world, d, filter)
	assert(!found, "layer edits update native query filters")
	filter.layers = 4
	entity, _, found = ray(&world, d, filter)
	assert(found && entity == other_layer)
	filter.layers = 0
	_, _, found = ray(&world, d, filter)
	assert(!found)
	filter = ecs.Default_Physics_Query_Filter
	filter.layers = 1
	assert(len(overlap(&world, d, {5, 0, 0}, 0.1, filter)) == 1)
	filter.include_sensors = false
	assert(len(overlap(&world, d, {5, 0, 0}, 0.1, filter)) == 0)
	filter.include_sensors = true
	filter.ignore = sensor
	assert(len(overlap(&world, d, {5, 0, 0}, 0.1, filter)) == 0)
	filter.ignore = 0
	assert(
		len(overlap(&world, d, {15.9, 0.9, 0}, 0.05, filter, box = true)) == 0,
		"exact shape overlap, not AABB",
	)
	assert(len(overlap(&world, d, {15, 0, 0}, 0.05, filter, box = true)) == 1)
	if d == 3 {
		add(&world, registry, ball, "BoxCollider", `{"size":[1,1,1]}`)
		hits := overlap(&world, d, {15, 0, 0}, 2, filter)
		assert(len(hits) == 1 && hits[0] == ball, "multiple shapes deduplicate to one entity")
	}
	move(&world, wall, 18)
	filter.include_sensors = false
	entity, _, found = ray(&world, d, filter)
	assert(found && entity == ball, "query observes transform edits immediately")
	assert(ecs.destroy_entity(&world, ball))
	entity, _, found = ray(&world, d, filter)
	assert(found && entity == wall, "destroyed body absent from queries")
	assert(!ecs.set_runtime_field(&world, registry, sensor, box_name(d), "is_sensor", parse("17")))
	assert(
		ecs.set_runtime_field(&world, registry, sensor, box_name(d), "is_sensor", parse("false")),
	)
	entity, _, found = ray(&world, d, filter)
	assert(found && entity == sensor, "runtime sensor edit rebuilds native shape")
	snapshot, ok := ecs.runtime_component_json(&world, sensor, box_name(d))
	assert(ok)
	object := snapshot.(json.Object)
	assert(object["is_sensor"].(json.Boolean) == false)
	assert(len(overlap(&world, d, {}, -1)) == 0)
	if d == 2 {
		_, ok := ecs.physics_2d_raycast(&world, {}, {})
		assert(!ok)
		owned := ecs.physics_2d_overlap_box(
			&world,
			{10, 0},
			{20, 20},
			allocator = context.allocator,
		)
		delete(owned)
	} else {
		_, ok := ecs.physics_3d_raycast(&world, {}, {})
		assert(!ok)
		owned := ecs.physics_3d_overlap_box(
			&world,
			{10, 0, 0},
			{20, 20, 20},
			allocator = context.allocator,
		)
		delete(owned)
	}
}

validate_events :: proc(registry: ^ecs.Component_Registry, d: int, sensor: bool) {
	world := ecs.init()
	defer ecs.destroy(&world)
	first := body(&world, registry, d, 0, sensor, false)
	second := body(&world, registry, d, 0.5, false, true)
	step(&world, d)
	items := events(&world, d)
	assert(
		len(items) == 1 && items[0].kind == .Begin && items[0].is_sensor == sensor,
		"begin event",
	)
	assert(items[0].a.component == box_name(d) && items[0].b.component == box_name(d))
	if sensor {
		assert(items[0].a.entity == first && items[0].b.entity == second)
		transform, _ := ecs.get_transform(&world, second)
		assert(
			math.abs(transform.position[0] - 0.5) < 0.001,
			"sensor applies no collision response",
		)
	}
	step(&world, d)
	assert(len(events(&world, d)) == 0, "no repeated begin while touching")
	move(&world, second, 10)
	end_count := 0
	for _ in 0 ..< 4 {
		step(&world, d)
		for event in events(&world, d) {if event.kind == .End {end_count += 1}}
	}
	assert(end_count == 1, "one separation end")
	move(&world, second, 0.5)
	step(&world, d)
	items = events(&world, d)
	assert(len(items) == 1 && items[0].kind == .Begin, "re-entry")
	// Removal during iteration must neither append to nor invalidate this slice.
	assert(ecs.destroy_entity(&world, second))
	assert(len(items) == 1 && items[0].kind == .Begin)
	step(&world, d)
	items = events(&world, d)
	assert(len(items) == 1 && items[0].kind == .End, "removal end")
	assert(!ecs.is_alive(&world, second))
	step(&world, d)
	assert(len(events(&world, d)) == 0, "native end must not duplicate synthesized removal end")
	if d == 2 {ecs.physics_2d_shutdown(&world)} else {ecs.physics_3d_shutdown(&world)}
	assert(len(events(&world, d)) == 0)
	step(&world, d)
	assert(len(events(&world, d)) == 0, "shutdown clears old pairs")
}

validate_rebuild :: proc(registry: ^ecs.Component_Registry, d: int) {
	world := ecs.init()
	defer ecs.destroy(&world)
	sensor := body(&world, registry, d, 0, true, false)
	_ = body(&world, registry, d, 0, false, true)
	step(&world, d)
	assert(len(events(&world, d)) == 1)
	assert(ecs.set_runtime_field(&world, registry, sensor, box_name(d), "size.0", parse("4")))
	step(&world, d)
	items := events(&world, d)
	assert(
		len(items) == 2 && items[0].kind == .End && items[1].kind == .Begin,
		"rebuilding a touching collider retires old pair before new begin",
	)
	assert(ecs.set_entity_layer_mask(&world, sensor, 2))
	step(&world, d)
	items = events(&world, d)
	assert(len(items) == 1 && items[0].kind == .End, "filter change retires touching pair")
	step(&world, d)
	assert(len(events(&world, d)) == 0)
}

validate_round_sensor :: proc(registry: ^ecs.Component_Registry, d: int) {
	world := ecs.init()
	defer ecs.destroy(&world)
	sensor := body(&world, registry, d, 0, true, false, round = true)
	visitor := body(&world, registry, d, 0, false, true)
	step(&world, d)
	items := events(&world, d)
	assert(len(items) == 1 && items[0].is_sensor && items[0].kind == .Begin)
	assert(items[0].a.entity == sensor && items[0].a.component == round_name(d))
	assert(items[0].b.entity == visitor)
	// Native handles map back without borrowing a movable World pointer.
	if d == 2 {
		native, ok := ecs.physics_2d_native_body(&world, sensor)
		assert(ok)
		for id, owner in world.physics_2d.shapes {
			if owner.entity != sensor {continue}
			shape := transmute(b2.ShapeId)id
			mapped, found := ecs.physics_2d_entity_from_shape(&world, shape)
			assert(found && mapped == owner && b2.Shape_IsSensor(shape))
			assert(b2.Shape_GetBody(shape) == native)
		}
	} else {
		native, ok := ecs.physics_3d_native_body(&world, sensor)
		assert(ok)
		for id, owner in world.physics_3d.shapes {
			if owner.entity != sensor {continue}
			shape := b3.LoadShapeId(id)
			mapped, found := ecs.physics_3d_entity_from_shape(&world, shape)
			assert(found && mapped == owner && b3.Shape_IsSensor(shape))
			assert(b3.Shape_GetBody(shape) == native)
		}
	}
}

post_count: int
post_begins: int
post :: proc(engine: ^rune.Engine, world: ^ecs.World) {
	post_count += 1
	for event in ecs.physics_2d_events(world) {if event.kind == .Begin {post_begins += 1}}
}

validate_pipeline :: proc(registry: ^ecs.Component_Registry) {
	world := ecs.init()
	defer ecs.destroy(&world)
	_ = body(&world, registry, 2, 0, true, false)
	_ = body(&world, registry, 2, 0, false, true)
	engine := rune.Engine {
		fixed_delta_time = ecs.Physics2D_Fixed_Delta,
		delta_time       = 3 * ecs.Physics2D_Fixed_Delta,
	}
	engine.systems = make([dynamic]rune.System)
	defer delete(engine.systems)
	append(&engine.systems, rune.System{name = "events", post_physics = post})
	rune.run_fixed_pipeline(&engine, &world)
	assert(post_count == 3 && post_begins == 1, "post_physics observes each substep exactly once")
}

validate_query_sync :: proc(registry: ^ecs.Component_Registry) {
	world := ecs.init()
	defer ecs.destroy(&world)
	entity := body(&world, registry, 2, 10, false, true)
	_, _, _ = ray(&world, 2)
	assert(!world.physics_2d.needs_sync)
	native, ok := ecs.physics_2d_native_body(&world, entity)
	assert(ok)
	b2.Body_SetLinearVelocity(native, {7,0})
	_, _, _ = ray(&world, 2)
	assert(b2.Body_GetLinearVelocity(native).x == 7, "queries must not reapply simulation velocities")
	_ = body(&world, registry, 2, 30, false, false)
	assert(world.physics_2d.needs_sync)
	_, _, _ = ray(&world, 2)
	assert(!world.physics_2d.needs_sync && b2.Body_GetLinearVelocity(native).x == 7)
}

main :: proc() {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	for d in 2 ..= 3 {
		validate_queries(&registry, d)
		validate_events(&registry, d, true)
		validate_events(&registry, d, false)
		validate_rebuild(&registry, d)
		validate_round_sensor(&registry, d)
	}
	validate_pipeline(&registry)
	validate_query_sync(&registry)
	fmt.println("Physics queries, sensors, buffered events, and post-physics lifecycle passed")
}
