package ecs

// Advance one query capsule against the current native shapes without stepping
// the rigid-body world or other character controllers. This is an explicit
// alternative to the normal fixed-step scene update, not an extra update to
// call after physics_3d_update for the same actor and interval.
character_controller_3d_step :: proc(world:^World,entity:Entity,dt:f32)->bool {
	if world==nil || entity==0 || !finite_nonnegative(dt) || dt==0 || !character_controller_3d_ready(world,entity) {return false}
	ensure_box3d_world(world)
	sync_bodies_to_box3d(world)
	character_controllers_3d_step(world,dt,entity)
	return true
}
