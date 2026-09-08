package ecs

import "base:runtime"
import b2 "vendor:box2d"

// Frozen before each native step: pre-solve may run on worker threads, so it
// only reads this snapshot and never mutates Rune or the native world.
One_Way_Shape_2D :: struct {
	id: u64,
	entity: Entity,
	component: string,
	bounds: b2.AABB,
	previous_bounds: b2.AABB,
	has_previous: bool,
	velocity: [2]f32,
	one_way: bool,
}
One_Way_Callback_2D :: struct {caller_context: runtime.Context, world: ^World}

one_way_enabled_2d :: proc(world: ^World, entity: Entity, component: string) -> bool {
	switch component {
	case "BoxCollider2D": return world.box_colliders_2d[entity].one_way
	case "SegmentCollider2D": return world.segment_colliders_2d[entity].one_way
	}
	return false
}

one_way_shape_2d :: proc(world: ^World, shape: b2.ShapeId) -> One_Way_Shape_2D {
	owner := world.physics_2d.shapes[transmute(u64)shape]
	return {id=transmute(u64)shape,entity=owner.entity,component=owner.component,bounds=b2.Shape_GetAABB(shape),
		velocity=character_support_velocity_2d(world,owner.entity),
		one_way=one_way_enabled_2d(world,owner.entity,owner.component)}
}

one_way_prepare_2d :: proc(world: ^World) {
	any_one_way := false
	for entity, c in world.box_colliders_2d {if c.one_way && is_enabled(world,entity) {any_one_way = true; break}}
	if !any_one_way {for entity, c in world.segment_colliders_2d {if c.one_way && is_enabled(world,entity) {any_one_way = true; break}}}
	if !any_one_way {clear(&world.one_way_shapes_2d);clear(&world.one_way_contacts_2d); return}
	for id in world.one_way_shapes_2d {if _,found := world.physics_2d.shapes[id]; !found {delete_key(&world.one_way_shapes_2d,id)}}
	for id in world.physics_2d.shapes {
		shape := transmute(b2.ShapeId)id
		if b2.Shape_IsValid(shape) {
			current := one_way_shape_2d(world,shape)
			previous,found := world.one_way_shapes_2d[id]
			current.previous_bounds,current.has_previous = previous.bounds,found
			world.one_way_shapes_2d[id] = current
		}
	}
}

// Positive Y is down. Only the horizontal top face catches visitors arriving
// from above and moving down relative to the platform. Slop covers resting
// contact penetration; it does not grow with the platform's thickness.
one_way_accepts_2d :: proc(world: ^World, platform, visitor: One_Way_Shape_2D, normal: b2.Vec2) -> bool {
	if !platform.one_way {return true}
	state := world.character_controller_states_2d[visitor.entity]
	if state.drop_entity == platform.entity && state.drop_component == platform.component {return false}
	above := visitor.bounds.upperBound.y <= platform.bounds.lowerBound.y+0.1
	// Discrete contacts can first reach pre-solve one step after crossing. The
	// previous sample admits that crossing without admitting a body spawned inside.
	crossed := platform.has_previous && visitor.has_previous &&
		visitor.previous_bounds.upperBound.y <= platform.previous_bounds.lowerBound.y+0.1
	resting := world.one_way_contacts_2d[one_way_pair_2d(platform.id,visitor.id)]
	return normal.y < -0.5 && (above || crossed || resting) &&
		visitor.velocity[1] >= platform.velocity[1]-0.01
}

one_way_contact_2d :: proc(world: ^World, shape_a, shape_b: b2.ShapeId, normal: b2.Vec2) -> bool {
	a,has_a := world.one_way_shapes_2d[transmute(u64)shape_a]
	b,has_b := world.one_way_shapes_2d[transmute(u64)shape_b]
	if !has_a || !has_b {return true}
	return one_way_accepts_2d(world,a,b,normal) && one_way_accepts_2d(world,b,a,-normal)
}

one_way_pre_solve_2d :: proc "c" (a,b: b2.ShapeId, manifold: ^b2.Manifold, ctx: rawptr) -> bool {
	callback := cast(^One_Way_Callback_2D)ctx
	context = callback.caller_context
	return one_way_contact_2d(callback.world,a,b,manifold.normal)
}

one_way_cast_2d :: proc(world: ^World, entity: Entity, shape: b2.ShapeId, normal: b2.Vec2) -> bool {
	platform := one_way_shape_2d(world,shape)
	if !platform.one_way {return true}
	capsule,_ := get_effective_capsule_collider_2d(world,entity)
	a,b,radius := capsule_collider_2d_geometry(capsule,world.transforms[entity])
	visitor := One_Way_Shape_2D{entity=entity,velocity=character_support_velocity_2d(world,entity)}
	visitor.bounds.upperBound.y = max(a[1],b[1])+radius
	return one_way_accepts_2d(world,platform,visitor,normal)
}

// Request an intentional departure from the current one-way support. The
// request is consumed at the next fixed step and takes priority over jumping.
character_controller_2d_drop_through :: proc(world: ^World, entity: Entity) -> bool {
	state,found := world.character_controller_states_2d[entity]
	if !found || !state.active || !state.grounded || !is_enabled(world,entity) ||
		!one_way_enabled_2d(world,state.support_entity,state.support_component) {return false}
	state.drop_requested = true
	world.character_controller_states_2d[entity] = state
	return true
}

character_drop_guard_2d :: proc(world: ^World, entity: Entity, state: ^Character_Controller_State_2D, dt: f32) {
	if state.drop_entity == 0 {return}
	state.drop_remaining = max(0,state.drop_remaining-dt)
	if state.drop_remaining > 0 {return}
	capsule,_ := get_effective_capsule_collider_2d(world,entity)
	a,b,radius := capsule_collider_2d_geometry(capsule,world.transforms[entity])
	for id, owner in world.physics_2d.shapes {
		if owner.entity != state.drop_entity || owner.component != state.drop_component {continue}
		shape := transmute(b2.ShapeId)id
		if !b2.Shape_IsValid(shape) {continue}
		bounds := b2.Shape_GetAABB(shape)
		// Keep ignoring while overlapping its height. A later jump may clear
		// above it when a low floor prevented full clearance below.
		if min(a[1],b[1])-radius <= bounds.upperBound.y+0.05 &&
			max(a[1],b[1])+radius >= bounds.lowerBound.y-0.05 &&
			max(a[0],b[0])+radius >= bounds.lowerBound.x && min(a[0],b[0])-radius <= bounds.upperBound.x {return}
	}
	state.drop_entity,state.drop_component = 0,""
}

one_way_pair_2d :: proc(a,b:u64)->Physics_Pair {return {min(a,b),max(a,b),false}}

// Keep admitted contacts through the solver's gradual penetration correction.
// Rebuild on the game thread; the pre-solve callback only reads the prior set.
one_way_finish_2d :: proc(world:^World) {
	if len(world.one_way_shapes_2d)==0 {return}
	admitted := make([dynamic]Physics_Pair,context.temp_allocator)
	for _,native in world.box2d_bodies {
		if b2.Body_GetType(native)!=.dynamicBody {continue}
		buffer:=make([]b2.ContactData,int(b2.Body_GetContactCapacity(native)),context.temp_allocator)
		for contact in b2.Body_GetContactData(native,buffer) {
			a,b:=transmute(u64)contact.shapeIdA,transmute(u64)contact.shapeIdB
			if !world.one_way_shapes_2d[a].one_way && !world.one_way_shapes_2d[b].one_way {continue}
			if contact.manifold.pointCount>0 && one_way_contact_2d(world,contact.shapeIdA,contact.shapeIdB,contact.manifold.normal) {
				append(&admitted,one_way_pair_2d(a,b))
			}
		}
	}
	clear(&world.one_way_contacts_2d)
	for pair in admitted {world.one_way_contacts_2d[pair]=true}
}

one_way_forget_2d :: proc(world:^World,entity:Entity) {
	for id,shape in world.one_way_shapes_2d {
		if shape.entity != entity {continue}
		delete_key(&world.one_way_shapes_2d,id)
		for pair in world.one_way_contacts_2d {if pair.a==id || pair.b==id {delete_key(&world.one_way_contacts_2d,pair)}}
	}
}
