package ecs

import "base:runtime"
import "core:c"
import "core:math"
import b3 "vendor:box3d"

Character_Skin_3D :: f32(0.005)
Character_Plane_Query_3D :: struct {
	caller_context: runtime.Context,
	world: ^World,
	entity: Entity,
	min_up: f32,
	planes: [dynamic]b3.CollisionPlane,
	owners: [dynamic]Entity,
	points: [dynamic][3]f32,
}
Character_Cast_Query_3D :: struct {
	caller_context: runtime.Context,
	world: ^World,
	entity: Entity,
	found: bool,
	hit: Raycast_Hit_3D,
}

character_vec_3d :: proc(v: [3]f32) -> b3.Vec3 {return {v[0],v[1],v[2]}}
character_array_3d :: proc(v: b3.Vec3) -> [3]f32 {return {v.x,v.y,v.z}}
character_dot_3d :: proc(a,b: [3]f32) -> f32 {return a[0]*b[0]+a[1]*b[1]+a[2]*b[2]}
character_length_3d :: proc(v: [3]f32) -> f32 {return math.sqrt(character_dot_3d(v,v))}
character_capsule_3d :: proc(radius,height: f32) -> b3.Capsule {
	return {center1={0,radius,0},center2={0,height-radius,0},radius=radius}
}
character_filter_3d :: proc(world: ^World, entity: Entity) -> b3.QueryFilter {
	mask,_ := entity_layer_mask(world,entity)
	return {categoryBits=mask,maskBits=mask}
}
character_accept_shape_3d :: proc(world: ^World, entity: Entity, shape: b3.ShapeId) -> (Entity,bool) {
	owner,found := physics_3d_entity_from_shape(world,shape)
	return owner.entity, found && owner.entity != entity && is_enabled(world,owner.entity) && !b3.Shape_IsSensor(shape)
}
character_mover_filter_3d :: proc "c"(shape:b3.ShapeId,ctx:rawptr)->bool {
	query := cast(^Character_Plane_Query_3D)ctx
	context = query.caller_context
	_,accepted := character_accept_shape_3d(query.world,query.entity,shape)
	return accepted
}
character_plane_result_3d :: proc "c"(shape:b3.ShapeId,planes:[^]b3.PlaneResult,count:c.int,ctx:rawptr)->bool {
	query := cast(^Character_Plane_Query_3D)ctx
	context = query.caller_context
	owner,accepted := character_accept_shape_3d(query.world,query.entity,shape)
	if !accepted {return true}
	for i in 0..<int(count) {
		plane := planes[i].plane
		plane.offset += Character_Skin_3D-0.02
		append(&query.planes,b3.CollisionPlane{plane=plane,pushLimit=1.0e30,clipVelocity=true})
		append(&query.owners,owner)
		append(&query.points,character_array_3d(planes[i].point))
		// Keep the physical plane for downhill sliding, plus a horizontal
		// barrier so steep surfaces cannot convert forward input into a climb.
		if plane.normal.y > 0.01 && plane.normal.y < query.min_up {
			horizontal:=b3.Vec3{plane.normal.x,0,plane.normal.z}
			length:=math.sqrt(horizontal.x*horizontal.x+horizontal.z*horizontal.z)
			horizontal.x/=length;horizontal.z/=length
			barrier:=b3.Plane{normal=horizontal,offset=plane.offset/length}
			append(&query.planes,b3.CollisionPlane{plane=barrier,pushLimit=1.0e30,clipVelocity=true})
			append(&query.owners,owner)
			append(&query.points,character_array_3d(planes[i].point))
		}
	}
	return true
}
character_collect_planes_3d :: proc(query:^Character_Plane_Query_3D,position:[3]f32,radius,height:f32) {
	clear(&query.planes);clear(&query.owners);clear(&query.points)
	capsule := character_capsule_3d(radius,height)
	capsule.radius += 0.02 // Include near contacts, then subtract the margin from plane offsets.
	b3.World_CollideMover(query.world.box3d_world,{position[0],position[1],position[2]},
		capsule,character_filter_3d(query.world,query.entity),character_plane_result_3d,query)
}
character_cast_result_3d :: proc "c"(shape:b3.ShapeId,point:b3.Pos,normal:b3.Vec3,fraction:f32,user_material:u64,triangle,child:c.int,ctx:rawptr)->f32 {
	query := cast(^Character_Cast_Query_3D)ctx
	context = query.caller_context
	owner,accepted := character_accept_shape_3d(query.world,query.entity,shape)
	if !accepted {return -1}
	if !query.found || fraction < query.hit.fraction {
		query.found = true
		query.hit = {entity=owner,point={f32(point.x),f32(point.y),f32(point.z)},
			normal=character_array_3d(normal),fraction=fraction}
	}
	return query.hit.fraction
}
character_sweep_3d :: proc(world:^World,entity:Entity,position,delta:[3]f32,radius,height:f32)->(Raycast_Hit_3D,bool) {
	points := [2]b3.Vec3{{0,radius,0},{0,height-radius,0}}
	proxy := b3.ShapeProxy{points=raw_data(points[:]),count=2,radius=radius}
	query := Character_Cast_Query_3D{caller_context=context,world=world,entity=entity}
	_ = b3.World_CastShape(world.box3d_world,{position[0],position[1],position[2]},proxy,
		character_vec_3d(delta),character_filter_3d(world,entity),character_cast_result_3d,&query)
	return query.hit,query.found
}

// Solve contact planes, then sweep the entire capsule to avoid tunneling.
// Re-query after impact so the unconsumed displacement can slide at corners.
character_slide_3d :: proc(query:^Character_Plane_Query_3D,position,translation:[3]f32,radius,height:f32)->[3]f32 {
	result := position
	remaining := translation
	for _ in 0..<6 {
		character_collect_planes_3d(query,result,radius,height)
		solved := b3.SolvePlanes(character_vec_3d(remaining),raw_data(query.planes),c.int(len(query.planes)))
		delta := character_array_3d(solved.delta)
		if character_length_3d(delta) < 0.00001 {break}
		fraction := b3.World_CastMover(query.world.box3d_world,{result[0],result[1],result[2]},
			character_capsule_3d(radius,height),character_vec_3d(delta),character_filter_3d(query.world,query.entity),
			character_mover_filter_3d,query)
		result += delta*fraction
		remaining = delta*(1-fraction)
		if fraction >= 0.9999 {break}
	}
	character_collect_planes_3d(query,result,radius,height)
	correction := b3.SolvePlanes({},raw_data(query.planes),c.int(len(query.planes)))
	result += character_array_3d(correction.delta)
	return result
}

character_ground_3d :: proc(world:^World,entity:Entity,position:[3]f32,radius,height,distance,min_up:f32)->(Raycast_Hit_3D,[3]f32,bool) {
	// Begin slightly above the feet to avoid initial-contact casts being ignored.
	origin := position+[3]f32{0,0.03,0}
	delta := [3]f32{0,-(distance+0.03),0}
	hit,found := character_sweep_3d(world,entity,origin,delta,radius,height)
	if !found || hit.normal[1] < min_up {return {},position,false}
	landing := origin+delta*hit.fraction+[3]f32{0,Character_Skin_3D,0}
	return hit,landing,true
}

character_try_step_3d :: proc(query:^Character_Plane_Query_3D,start,translation,ordinary:[3]f32,config:CharacterController3D,height,min_up:f32)->([3]f32,bool) {
	if config.step_height == 0 {return ordinary,false}
	horizontal := [3]f32{translation[0],0,translation[2]}
	distance := character_length_3d(horizontal)
	if distance < 0.0001 {return ordinary,false}
	direction := horizontal/distance
	ordinary_progress := character_dot_3d(ordinary-start,direction)
	if ordinary_progress >= distance-0.001 {return ordinary,false}
	lift := [3]f32{0,config.step_height,0}
	if hit,blocked := character_sweep_3d(query.world,query.entity,start,lift,config.radius,height); blocked && hit.fraction < 1 {return ordinary,false}
	raised := start+lift
	advanced := character_slide_3d(query,raised,horizontal,config.radius,height)
	_,landing,grounded := character_ground_3d(query.world,query.entity,advanced,config.radius,height,config.step_height+config.ground_snap_distance,min_up)
	rise := landing[1]-start[1]
	if !grounded || rise <= 0.01 || rise > config.step_height+0.01 ||
		character_dot_3d(landing-start,direction) <= ordinary_progress+0.001 {return ordinary,false}
	return landing,true
}

character_overlap_result_3d :: proc "c"(shape:b3.ShapeId,ctx:rawptr)->bool {
	query:=cast(^Character_Cast_Query_3D)ctx
	context=query.caller_context
	_,accepted:=character_accept_shape_3d(query.world,query.entity,shape)
	if accepted {query.found=true}
	return !query.found
}
character_clearance_3d :: proc(world:^World,entity:Entity,position:[3]f32,radius,height:f32)->bool {
	points := [2]b3.Vec3{{0,radius,0},{0,height-radius,0}}
	// Ignore touching within solver slop, but detect even deep initial overlap.
	proxy := b3.ShapeProxy{points=raw_data(points[:]),count=2,radius=max(radius-0.005,radius*0.9)}
	query:=Character_Cast_Query_3D{caller_context=context,world=world,entity=entity}
	_=b3.World_OverlapShape(world.box3d_world,{position[0],position[1],position[2]},proxy,
		character_filter_3d(world,entity),character_overlap_result_3d,&query)
	return !query.found
}
