package ecs

import b3 "vendor:box3d"

// Query-only character capsules are absent from physics_3d_raycast. This bounded
// ray tests one controller's current posture; padding allows a finite-size shot.
character_controller_3d_raycast :: proc(world: ^World, entity: Entity, origin, translation: [3]f32, padding: f32 = 0) -> (Raycast_Hit_3D, bool) {
	if world==nil || !character_controller_3d_ready(world,entity) ||
	   !physics_query_vector_valid(origin) || !physics_query_vector_valid(translation) ||
	   translation==([3]f32{}) || !finite_nonnegative(padding) {return {},false}
	pose,_:=get_transform(world,entity)
	config,_:=get_character_controller_3d(world,entity)
	state,_:=get_character_controller_3d_state(world,entity)
	height:=state.height if state.height>=2*config.radius else config.height
	up:=state.up
	if length:=character_length_3d(up); length>0.001 {up/=length} else {up={0,1,0}}
	capsule:=character_capsule_3d(config.radius,height,up); capsule.radius+=padding
	local_origin:=origin-pose.position
	point:=character_vec_3d(local_origin)
	proxy:=b3.ShapeProxy{points=&point,count=1,radius=0}
	if b3.OverlapCapsule(capsule,b3.Transform_identity,proxy) {
		return {entity=entity,component="CharacterController3D",point=origin,normal=-translation/character_length_3d(translation),fraction=0},true
	}
	hit:=b3.RayCastCapsule(capsule,{origin=point,translation=character_vec_3d(translation),maxFraction=1})
	if !hit.hit {return {},false}
	return {entity=entity,component="CharacterController3D",point=pose.position+character_array_3d(hit.point),normal=character_array_3d(hit.normal),fraction=hit.fraction},true
}
