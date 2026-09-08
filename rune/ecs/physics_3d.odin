package ecs

import "core:encoding/json"
import b3 "vendor:box3d"

RigidBody3D :: struct {
	velocity:            [3]f32,
	angular_velocity:    [3]f32,
	gravity_scale:       f32,
	body_type:           string,
	linear_damping:      f32,
	angular_damping:     f32,
	allow_fast_rotation: bool,
}

Physics3D_Fixed_Delta: f32 : 1.0 / 60.0
Physics3D_Gravity: f32 : -9.8
Radians_Per_Degree: f32 : 0.017453292519943295

rigid_body_3d_from_json :: proc(data: json.Value) -> (RigidBody3D, bool) {
	object, ok := data.(json.Object)
	if !ok {return {}, false}
	result := RigidBody3D {
		gravity_scale = 1,
		body_type     = "dynamic",
	}
	if value, found := object["velocity"];
	   found && !read_vector3(value, &result.velocity) {return {}, false}
	if value, found := object["angular_velocity"];
	   found && !read_vector3(value, &result.angular_velocity) {return {}, false}
	if value, found := object["gravity_scale"];
	   found {result.gravity_scale, ok = read_number(value); if !ok || result.gravity_scale < 0 {return {}, false}}
	if value, found := object["linear_damping"];
	   found {result.linear_damping, ok = read_number(value); if !ok || result.linear_damping < 0 {return {}, false}}
	if value, found := object["angular_damping"];
	   found {result.angular_damping, ok = read_number(value); if !ok || result.angular_damping < 0 {return {}, false}}
	if value, found := object["allow_fast_rotation"];
	   found {result.allow_fast_rotation, ok = value.(json.Boolean); if !ok {return {}, false}}
	if value, found := object["type"]; found {
		result.body_type, ok = value.(json.String)
		if !ok ||
		   (result.body_type != "dynamic" &&
				   result.body_type != "kinematic" &&
				   result.body_type != "static") {return {}, false}
	}
	return result, component_value_valid(result)
}

physics_3d_update :: proc(world: ^World, dt: f32) {
	physics_begin_update(&world.physics_3d)
	if dt <= 0 ||
	   (len(world.rigid_bodies_3d) == 0 &&
			   len(world.box_colliders) == 0 &&
			   len(world.sphere_colliders) == 0) {return}
	ensure_box3d_world(world)
	world.physics_3d_accumulator += dt
	steps := 0
	for world.physics_3d_accumulator >= Physics3D_Fixed_Delta && steps < 8 {
		sync_bodies_to_box3d(world)
		b3.World_Step(world.box3d_world, Physics3D_Fixed_Delta, 4)
		collect_box3d_events(world)
		sync_bodies_from_box3d(world)
		world.physics_3d_accumulator -= Physics3D_Fixed_Delta
		steps += 1
	}
	if steps == 8 {world.physics_3d_accumulator = 0}
}

physics_3d_shutdown :: proc(world: ^World) {
	if world == nil {return}
	physics_state_reset(&world.physics_3d)
	if !b3.IS_NULL(world.box3d_world) && b3.World_IsValid(world.box3d_world) {
		b3.DestroyWorld(world.box3d_world)
	}
	world.box3d_world = {}
	delete(world.box3d_bodies)
	world.box3d_bodies = make(map[Entity]b3.BodyId)
	world.physics_3d_accumulator = 0
}

physics_3d_remove_entity :: proc(world: ^World, entity: Entity) {
	world.physics_3d.needs_sync = true
	if native, found := world.box3d_bodies[entity]; found {
		physics_forget_entity(&world.physics_3d, entity)
		if !b3.IS_NULL(native) && b3.Body_IsValid(native) {b3.DestroyBody(native)}
		delete_key(&world.box3d_bodies, entity)
	}
}

physics_3d_native_body :: proc(world: ^World, entity: Entity) -> (b3.BodyId, bool) {
	body, found := world.box3d_bodies[entity]
	return body, found && !b3.IS_NULL(body) && b3.Body_IsValid(body)
}

physics_3d_counters :: proc(world: ^World) -> (b3.Counters, bool) {
	if world == nil ||
	   b3.IS_NULL(world.box3d_world) ||
	   !b3.World_IsValid(world.box3d_world) {return {}, false}
	return b3.World_GetCounters(world.box3d_world), true
}

ensure_box3d_world :: proc(world: ^World) {
	if !b3.IS_NULL(world.box3d_world) {return}
	def := b3.DefaultWorldDef()
	def.gravity = {0, Physics3D_Gravity, 0}
	world.box3d_world = b3.CreateWorld(def)
}

physics_3d_transform_edited :: proc(world: ^World, entity: Entity, previous, value: Transform) {
	if previous.scale != value.scale {
		physics_3d_remove_entity(world, entity)
		return
	}
	if native, found := physics_3d_native_body(world, entity); found {
		if previous.position != value.position || previous.rotation != value.rotation {
			rotation := b3.Body_GetRotation(native)
			if previous.rotation != value.rotation {rotation = transform_rotation_quat(value)}
			b3.Body_SetTransform(native, {value.position[0], value.position[1], value.position[2]}, rotation)
			b3.Body_SetAwake(native, true)
		}
	}
}

physics_3d_body_edited :: proc(world: ^World, entity: Entity, previous, value: RigidBody3D) {
	if previous.allow_fast_rotation != value.allow_fast_rotation {
		physics_3d_remove_entity(world, entity)
		return
	}
	native, found := physics_3d_native_body(world, entity)
	if !found {
		world.physics_3d.needs_sync = true
		return
	}
	type_changed := previous.body_type != value.body_type
	if type_changed {b3.Body_SetType(native, box3d_body_type(value.body_type))}
	if previous.gravity_scale != value.gravity_scale {b3.Body_SetGravityScale(native, value.gravity_scale)}
	if previous.linear_damping != value.linear_damping {b3.Body_SetLinearDamping(native, value.linear_damping)}
	if previous.angular_damping != value.angular_damping {b3.Body_SetAngularDamping(native, value.angular_damping)}
	if type_changed || previous.velocity != value.velocity {b3.Body_SetLinearVelocity(native, {value.velocity[0], value.velocity[1], value.velocity[2]})}
	if type_changed || previous.angular_velocity != value.angular_velocity {b3.Body_SetAngularVelocity(native, {value.angular_velocity[0], value.angular_velocity[1], value.angular_velocity[2]})}
	if previous != value {b3.Body_SetAwake(native, true)}
}

sync_bodies_to_box3d :: proc(world: ^World) {
	defer world.physics_3d.needs_sync = false
	for entity, body in world.rigid_bodies_3d {
		if !is_enabled(world, entity) {continue}
		if _, found := world.box3d_bodies[entity]; found {continue}
		create_box3d_body(world, entity, body)
	}
	for entity in world.box_colliders {
		if !is_enabled(world, entity) {continue}
		if _, has_native := world.box3d_bodies[entity]; has_native {continue}
		if _, has_body := world.rigid_bodies_3d[entity];
		   !has_body {create_box3d_static(world, entity)}
	}
	for entity in world.sphere_colliders {
		if !is_enabled(world, entity) {continue}
		if _, has_native := world.box3d_bodies[entity]; has_native {continue}
		if _, has_body := world.rigid_bodies_3d[entity];
		   !has_body {create_box3d_static(world, entity)}
	}
}

create_box3d_body :: proc(world: ^World, entity: Entity, body: RigidBody3D) {
	transform, found := get_transform(world, entity)
	if !found {return}
	if _, has_box := world.box_colliders[entity]; !has_box {
		if _, has_sphere := world.sphere_colliders[entity]; !has_sphere {return}
	}

	native := create_box3d_body_id(world, body, transform)
	if collider, has_collider := world.box_colliders[entity]; has_collider {
		create_box3d_box_shape(world, entity, native, collider, transform)
	}
	if collider, has_collider := world.sphere_colliders[entity]; has_collider {
		create_box3d_sphere_shape(world, entity, native, collider, transform)
	}
	world.box3d_bodies[entity] = native
}

create_box3d_static :: proc(world: ^World, entity: Entity) {
	transform, found := get_transform(world, entity)
	if !found {return}
	has_static_shape := false
	if collider, has_collider := world.box_colliders[entity]; has_collider && collider.is_static {
		has_static_shape = true
	}
	if collider, has_collider := world.sphere_colliders[entity];
	   has_collider && collider.is_static {
		has_static_shape = true
	}
	if !has_static_shape {return}

	body := RigidBody3D {
		gravity_scale = 0,
		body_type     = "static",
	}
	native := create_box3d_body_id(world, body, transform)
	if collider, has_collider := world.box_colliders[entity]; has_collider && collider.is_static {
		create_box3d_box_shape(world, entity, native, collider, transform)
	}
	if collider, has_collider := world.sphere_colliders[entity];
	   has_collider && collider.is_static {
		create_box3d_sphere_shape(world, entity, native, collider, transform)
	}
	world.box3d_bodies[entity] = native
}

sync_bodies_from_box3d :: proc(world: ^World) {
	for entity, &body in world.rigid_bodies_3d {
		if !is_enabled(world, entity) {continue}
		native, found := physics_3d_native_body(world, entity)
		if !found {continue}
		transform, has_transform := get_transform(world, entity)
		if !has_transform {continue}
		position := b3.Body_GetPosition(native)
		velocity := b3.Body_GetLinearVelocity(native)
		angular_velocity := b3.Body_GetAngularVelocity(native)
		transform.position = {f32(position.x), f32(position.y), f32(position.z)}
		body.velocity = {velocity.x, velocity.y, velocity.z}
		body.angular_velocity = {angular_velocity.x, angular_velocity.y, angular_velocity.z}
		if world.transforms[entity] != transform {record_component_change(world, entity, "Transform", .Changed)}
		if world.rigid_bodies_3d[entity] != body {record_component_change(world, entity, "RigidBody3D", .Changed)}
		world.transforms[entity] = transform
		world.rigid_bodies_3d[entity] = body
	}
}

create_box3d_body_id :: proc(world: ^World, body: RigidBody3D, transform: Transform) -> b3.BodyId {
	def := b3.DefaultBodyDef()
	def.type = box3d_body_type(body.body_type)
	def.position = {transform.position[0], transform.position[1], transform.position[2]}
	def.rotation = transform_rotation_quat(transform)
	def.linearVelocity = {body.velocity[0], body.velocity[1], body.velocity[2]}
	def.angularVelocity = {
		body.angular_velocity[0],
		body.angular_velocity[1],
		body.angular_velocity[2],
	}
	def.gravityScale = body.gravity_scale
	def.linearDamping = body.linear_damping
	def.angularDamping = body.angular_damping
	def.allowFastRotation = body.allow_fast_rotation
	return b3.CreateBody(world.box3d_world, def)
}

create_box3d_shape_def :: proc(
	world: ^World,
	entity: Entity,
	friction, restitution, rolling_resistance: f32,
) -> b3.ShapeDef {
	def := b3.DefaultShapeDef()
	def.density = 1
	def.enableSensorEvents = true
	def.enableContactEvents = true
	def.baseMaterial.friction = friction
	def.baseMaterial.restitution = restitution
	def.baseMaterial.rollingResistance = rolling_resistance
	if mask, found := entity_layer_mask(world, entity); found {
		def.filter.categoryBits = mask
		def.filter.maskBits = mask
	}
	return def
}

create_box3d_box_shape :: proc(
	world: ^World,
	entity: Entity,
	body: b3.BodyId,
	collider: BoxCollider,
	transform: Transform,
) {
	def := create_box3d_shape_def(
		world,
		entity,
		collider.friction,
		collider.restitution,
		collider.rolling_resistance,
	)
	def.isSensor = collider.is_sensor
	box := b3.MakeBoxHull(
		collider.size[0] * transform.scale[0] * 0.5,
		collider.size[1] * transform.scale[1] * 0.5,
		collider.size[2] * transform.scale[2] * 0.5,
	)
	id := b3.CreateHullShape(body, def, &box.base)
	world.physics_3d.shapes[b3.StoreShapeId(id)] = {entity, "BoxCollider"}
}

create_box3d_sphere_shape :: proc(
	world: ^World,
	entity: Entity,
	body: b3.BodyId,
	collider: SphereCollider,
	transform: Transform,
) {
	def := create_box3d_shape_def(
		world,
		entity,
		collider.friction,
		collider.restitution,
		collider.rolling_resistance,
	)
	def.isSensor = collider.is_sensor
	scale := transform.scale[0]
	if transform.scale[1] > scale {scale = transform.scale[1]}
	if transform.scale[2] > scale {scale = transform.scale[2]}
	sphere := b3.Sphere {
		radius = collider.radius * scale,
	}
	id := b3.CreateSphereShape(body, def, &sphere)
	world.physics_3d.shapes[b3.StoreShapeId(id)] = {entity, "SphereCollider"}
}

box3d_body_type :: proc(body_type: string) -> b3.BodyType {
	if body_type == "dynamic" {return .dynamicBody}
	if body_type == "kinematic" {return .kinematicBody}
	return .staticBody
}

transform_rotation_quat :: proc(transform: Transform) -> b3.Quat {
	x := b3.MakeQuatFromAxisAngle({1, 0, 0}, transform.rotation[0] * Radians_Per_Degree)
	y := b3.MakeQuatFromAxisAngle({0, 1, 0}, transform.rotation[1] * Radians_Per_Degree)
	z := b3.MakeQuatFromAxisAngle({0, 0, 1}, transform.rotation[2] * Radians_Per_Degree)
	return b3.NormalizeQuat(b3.MulQuat(b3.MulQuat(z, y), x))
}
