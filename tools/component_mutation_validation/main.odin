package main

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "rune:ecs"
import b2 "vendor:box2d"
import b3 "vendor:box3d"

parse :: proc(text: string) -> json.Value {
	value: json.Value
	assert(json.unmarshal(transmute([]u8)text, &value, allocator = context.temp_allocator) == nil)
	return value
}

add :: proc(world: ^ecs.World, registry: ^ecs.Component_Registry, entity: ecs.Entity, name, text: string) {
	assert(ecs.add_component(world, registry, entity, name, parse(text)), name)
}

fixture :: proc(registry: ^ecs.Component_Registry, dimension: int) -> (ecs.World, ecs.Entity) {
	world := ecs.init()
	entity := ecs.create_entity(&world)
	assert(ecs.set_entity_metadata(&world, entity, "body", "Body", "", ecs.Default_Layer_Mask))
	add(&world, registry, entity, "Transform", `{}`)
	if dimension == 2 {
		add(&world, registry, entity, "RigidBody2D", `{"gravity_scale":0}`)
		add(&world, registry, entity, "BoxCollider2D", `{"size":[2,2]}`)
	} else {
		add(&world, registry, entity, "RigidBody3D", `{"gravity_scale":0}`)
		add(&world, registry, entity, "BoxCollider", `{"size":[2,2,2]}`)
	}
	return world, entity
}

main :: proc() {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	validate_2d(&registry)
	validate_3d(&registry)
	validate_cached_state(&registry)
	fmt.println("Component mutation, native synchronization, and reload notifications passed")
}

validate_2d :: proc(registry: ^ecs.Component_Registry) {
	world, entity := fixture(registry, 2)
	defer ecs.destroy(&world)
	ecs.physics_2d_update(&world, ecs.Physics2D_Fixed_Delta)
	native := world.box2d_bodies[entity]
	transform, _ := ecs.get_transform(&world, entity)
	transform.position = {10,20,0}
	version := ecs.change_version(&world)
	assert(ecs.set_transform(&world, entity, transform))
	assert(ecs.change_version(&world) == version + 1)
	assert(world.box2d_bodies[entity] == native && b2.Body_GetPosition(native).x == 10)
	version = ecs.change_version(&world)
	transform.position[0] = 12
	assert(ecs.set(&world, entity, transform))
	assert(ecs.change_version(&world) == version + 1, "generic set must not double-notify")
	body, _ := ecs.get_rigid_body_2d(&world, entity)
	body.velocity = {4,0}
	assert(ecs.set_rigid_body_2d(&world, entity, body))
	assert(world.box2d_bodies[entity] == native && b2.Body_GetLinearVelocity(native).x == 4)
	version = ecs.change_version(&world)
	assert(!ecs.set(&world, entity, ecs.BoxCollider2D{size = {-1,2}}))
	assert(!ecs.set_runtime_field(&world, registry, entity, "BoxCollider2D", "size.0", parse("-1")))
	assert(ecs.change_version(&world) == version && b2.Body_IsValid(native))
	assert(ecs.set_runtime_field(&world, registry, entity, "Transform", "position.0", parse("30")))
	assert(ecs.change_version(&world) == version + 1 && world.box2d_bodies[entity] == native)
	assert(b2.Body_GetPosition(native).x == 30)
	assert(ecs.set_box_collider_2d(&world, entity, ecs.BoxCollider2D{size = {4,2}}))
	assert(!b2.Body_IsValid(native))
	ecs.physics_2d_update(&world, ecs.Physics2D_Fixed_Delta)
	native = world.box2d_bodies[entity]
	snapshot, other := fixture(registry, 2)
	add(&snapshot, registry, other, "Transform", `{"position":[50,20,0]}`)
	version = ecs.change_version(&world)
	assert(ecs.apply_value_snapshot(&world, &snapshot))
	ecs.destroy(&snapshot)
	assert(ecs.change_version(&world) == version + 1)
	assert(world.box2d_bodies[entity] == native && b2.Body_GetPosition(native).x == 50)
	version = ecs.change_version(&world)
	ecs.physics_2d_update(&world, ecs.Physics2D_Fixed_Delta)
	assert(len(ecs.changes_since(&world, ecs.Transform, version)) == 1, "solver movement must notify")

	// Static bodies must keep their identity between fixed steps as well.
	wall := ecs.create_entity(&world)
	add(&world, registry, wall, "Transform", `{"position":[100,100,0]}`)
	add(&world, registry, wall, "BoxCollider2D", `{}`)
	ecs.physics_2d_update(&world, ecs.Physics2D_Fixed_Delta)
	wall_native := world.box2d_bodies[wall]
	for _ in 0..<10 {ecs.physics_2d_update(&world, ecs.Physics2D_Fixed_Delta)}
	assert(world.box2d_bodies[wall] == wall_native)
	assert(b2.World_GetCounters(world.box2d_world).bodyCount == 2)
	assert(ecs.remove_component(&world, wall, "Transform"))
	assert(!b2.Body_IsValid(wall_native))
}

validate_3d :: proc(registry: ^ecs.Component_Registry) {
	world, entity := fixture(registry, 3)
	defer ecs.destroy(&world)
	ecs.physics_3d_update(&world, ecs.Physics3D_Fixed_Delta)
	native, found := ecs.physics_3d_native_body(&world, entity)
	assert(found)
	transform, _ := ecs.get_transform(&world, entity)
	transform.position = {10,20,30}
	version := ecs.change_version(&world)
	assert(ecs.set(&world, entity, transform))
	assert(ecs.change_version(&world) == version + 1)
	assert(world.box3d_bodies[entity] == native && b3.Body_GetPosition(native).x == 10)
	body, _ := ecs.get_rigid_body_3d(&world, entity)
	body.velocity = {6,0,0}
	body.angular_velocity = {0,2,0}
	assert(ecs.set_rigid_body_3d(&world, entity, body))
	assert(world.box3d_bodies[entity] == native && b3.Body_GetLinearVelocity(native).x == 6)
	assert(b3.Body_GetAngularVelocity(native).y == 2)
	version = ecs.change_version(&world)
	body.gravity_scale = -1
	assert(!ecs.set(&world, entity, body))
	assert(!ecs.set_runtime_field(&world, registry, entity, "RigidBody3D", "gravity_scale", parse("-1")))
	assert(ecs.change_version(&world) == version && b3.Body_IsValid(native))
	snapshot, other := fixture(registry, 3)
	add(&snapshot, registry, other, "RigidBody3D", `{"gravity_scale":0,"velocity":[9,0,0]}`)
	version = ecs.change_version(&world)
	assert(ecs.apply_value_snapshot(&world, &snapshot))
	ecs.destroy(&snapshot)
	assert(ecs.change_version(&world) == version + 1)
	assert(world.box3d_bodies[entity] == native && b3.Body_GetLinearVelocity(native).x == 9)
	version = ecs.change_version(&world)
	assert(ecs.set_runtime_field(&world, registry, entity, "Transform", "scale", parse("[2,2,2]")))
	assert(ecs.change_version(&world) == version + 1 && !b3.Body_IsValid(native))
	ecs.physics_3d_update(&world, ecs.Physics3D_Fixed_Delta)
	native, found = ecs.physics_3d_native_body(&world, entity)
	assert(found)
	version = ecs.change_version(&world)
	transform, _ = ecs.get_transform(&world, entity)
	transform.position[0] = transmute(f32)u32(0x7f800000)
	assert(!ecs.set_transform(&world, entity, transform))
	assert(ecs.change_version(&world) == version && b3.Body_IsValid(native))
}

validate_cached_state :: proc(registry: ^ecs.Component_Registry) {
	world, entity := fixture(registry, 2)
	defer ecs.destroy(&world)
	add(&world, registry, entity, "SpriteAnimator", `{"animation":"actor.json","clip":"walk"}`)
	world.sprite_animation_states[entity] = ecs.Sprite_Animation_State{elapsed = 0.25}
	assert(ecs.set_runtime_field(&world, registry, entity, "SpriteAnimator", "speed", parse("2")))
	assert(world.sprite_animation_states[entity].elapsed == 0.25)
	version := ecs.change_version(&world)
	assert(!ecs.set_runtime_field(&world, registry, entity, "SpriteAnimator", "speed", parse("0")))
	assert(ecs.change_version(&world) == version && world.sprite_animation_states[entity].elapsed == 0.25)
	assert(ecs.set_runtime_field(&world, registry, entity, "SpriteAnimator", "clip", parse(`"idle"`)))
	assert(world.sprite_animation_states[entity].elapsed == 0)
	add(&world, registry, entity, "CharacterController", `{}`)
	controller, _ := ecs.get_character_controller(&world, entity)
	controller.grounded = true
	controller.vertical_velocity = -3
	assert(ecs.set_character_controller(&world, entity, controller))
	assert(ecs.set_runtime_field(&world, registry, entity, "CharacterController", "jump_speed", parse("10")))
	controller, _ = ecs.get_character_controller(&world, entity)
	assert(controller.grounded && controller.vertical_velocity == -3 && controller.jump_speed == 10)
	add(&world, registry, entity, "AudioPlayer", `{"one":{"sound":"one.wav"},"two":{"sound":"two.wav"}}`)
	player, _ := ecs.get_audio_player(&world, entity, "one")
	player.volume = 0.5
	version = ecs.change_version(&world)
	assert(ecs.set_audio_player(&world, entity, "one", player))
	assert(ecs.change_version(&world) == version + 1)
	assert(len(ecs.changes_since(&world, ecs.AudioPlayer, version)) == 1)
	world.sprite_animation_states[entity] = ecs.Sprite_Animation_State{elapsed = 0.5, playing = true}
	snapshot, other := fixture(registry, 2)
	add(&snapshot, registry, other, "SpriteAnimator", `{"animation":"actor.json","clip":"idle","speed":3}`)
	add(&snapshot, registry, other, "CharacterController", `{"jump_speed":12}`)
	add(&snapshot, registry, other, "AudioPlayer", `{"one":{"sound":"one.wav","volume":0.3},"two":{"sound":"two.wav","volume":0.4}}`)
	version = ecs.change_version(&world)
	assert(ecs.apply_value_snapshot(&world, &snapshot))
	ecs.destroy(&snapshot)
	assert(ecs.change_version(&world) == version + 3, "reload must notify once per changed component, including named instances")
	assert(world.sprite_animation_states[entity].elapsed == 0.5 && world.sprite_animation_states[entity].playing)
	controller, _ = ecs.get_character_controller(&world, entity)
	assert(controller.grounded && controller.vertical_velocity == -3 && controller.jump_speed == 12)
	player, _ = ecs.get_audio_player(&world, entity, "two")
	assert(player.volume == 0.4)
	version = ecs.change_version(&world)
	assert(ecs.remove_component_instance(&world, entity, "AudioPlayer", "one"))
	assert(ecs.change_version(&world) == version + 1)
	data, _ := ecs.get_component(&world, entity, "AudioPlayer")
	assert(len(data.(json.Object)) == 1)
	assert(ecs.remove_component_instance(&world, entity, "AudioPlayer", "two"))
	assert(!ecs.has_component_data(&world, entity, "AudioPlayer"))
	assert(ecs.changes_since(&world, ecs.AudioPlayer, version)[0].kind == .Removed)

	add(&world, registry, entity, "Camera2D", `{"active":true}`)
	second := ecs.create_entity(&world)
	add(&world, registry, second, "Camera2D", `{"active":false}`)
	version = ecs.change_version(&world)
	assert(ecs.set_active_camera_2d(&world, second))
	assert(ecs.change_version(&world) == version + 2)
	assert(ecs.set_active_camera_2d(&world, second))
	assert(ecs.change_version(&world) == version + 2, "unchanged active selection must not notify")
}
