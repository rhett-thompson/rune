package r3d_bridge

import "core:math"
import "rune:ecs"
import rl "vendor:raylib"

Scene_Ray_Hit :: struct {
	entity: ecs.Entity,
	point: [3]f32,
	distance: f32,
	// Unit world-space surface normal, oriented toward the ray origin.
	normal: [3]f32,
}

scene_query_vector_valid :: proc(value:[3]f32) -> bool {
	for n in value {if math.is_nan(n) || math.is_inf(n) {return false}}
	return true
}

scene_query_unit :: proc(value:[3]f32) -> ([3]f32,bool) {
	if !scene_query_vector_valid(value) {return {},false}
	length:=rl.Vector3Length(value)
	if length<=0 || math.is_nan(length) || math.is_inf(length) {return {},false}
	return value/length,true
}

scene_query_in_subtree :: proc(world:^ecs.World,entity,root:ecs.Entity) -> bool {
	if root==0 {return false}
	for candidate:=entity; candidate!=0; candidate=world.parents[candidate] {
		if candidate==root {return true}
	}
	return false
}

// Picks visible cube/plane/quad/sphere primitives and runtime static meshes,
// including render-only meshes. Shader transparency and volumes are not tested.
// Translation is a complete world-space segment. No GPU context is required;
// an optional bridge context supplies cached static-mesh bounds.
// ignore remains exact; ignored_subtrees excludes each root and its descendants.
scene_raycast :: proc(world: ^ecs.World, origin, translation: [3]f32, ignore: ecs.Entity=0, bridge: ^Context=nil, ignored_subtrees:[]ecs.Entity=nil) -> (Scene_Ray_Hit,bool) {
	if world==nil {return {},false}
	length:=math.sqrt(translation[0]*translation[0]+translation[1]*translation[1]+translation[2]*translation[2])
	if length<=0 || math.is_nan(length) || math.is_inf(length) {return {},false}
	for value in origin {if math.is_nan(value) || math.is_inf(value) {return {},false}}
	ray:=rl.Ray{position=origin,direction=translation/length}
	result: Scene_Ray_Hit; found:=false
	for entity in world.entities {
		if entity==ignore || !ecs.is_enabled(world,entity) {continue}
		excluded:=false
		for root in ignored_subtrees {if scene_query_in_subtree(world,entity,root) {excluded=true; break}}
		if excluded {continue}
		mesh,has_mesh:=ecs.get_mesh_renderer(world,entity); sphere,has_sphere:=ecs.get_sphere_renderer(world,entity)
		if !has_mesh && !has_sphere {continue}
		pose,valid:=ecs.terrain_transform(world,entity); if !valid {continue}
		pose_matrix:=rl.MatrixTranslate(pose.position[0],pose.position[1],pose.position[2])*rl.QuaternionToMatrix(rotation_quaternion(pose))*rl.MatrixScale(pose.scale[0],pose.scale[1],pose.scale[2])
		inverse:=rl.MatrixInvert(pose_matrix)
		local_origin:=rl.Vector3Transform(ray.position,inverse)
		local_forward:=rl.Vector3Transform(ray.position+ray.direction,inverse)-local_origin
		local_ray:=rl.Ray{local_origin,rl.Vector3Normalize(local_forward)}
		hit: rl.RayCollision
		if has_mesh {
			switch mesh.primitive {
			case "cube": hit=rl.GetRayCollisionBox(local_ray,{{-0.5,-0.5,-0.5},{0.5,0.5,0.5}})
			case "plane": hit=rl.GetRayCollisionQuad(local_ray,{-0.5,0,-0.5},{-0.5,0,0.5},{0.5,0,0.5},{0.5,0,-0.5})
			case "quad": hit=rl.GetRayCollisionQuad(local_ray,{-0.5,-0.5,0},{0.5,-0.5,0},{0.5,0.5,0},{-0.5,0.5,0})
			case "static":
				if state,ok:=world.static_meshes[entity]; ok && len(state.data.vertices)>0 {
					bounds:=rl.BoundingBox{state.data.vertices[0].position,state.data.vertices[0].position}
					cached:=false
					if bridge!=nil {if cache,present:=bridge.static_meshes[entity]; present && bridge.static_mesh_generation==world.generation && cache.revision==state.revision {bounds=cache.mesh.aabb; cached=true}}
					if !cached {for v in state.data.vertices {for axis in 0..<3 {bounds.min[axis]=min(bounds.min[axis],v.position[axis]); bounds.max[axis]=max(bounds.max[axis],v.position[axis])}}}
					// Include flat paint meshes in the broad-phase box test.
					for axis in 0..<3 {bounds.min[axis]-=0.001; bounds.max[axis]+=0.001}
					if rl.GetRayCollisionBox(local_ray,bounds).hit {
						for i:=0; i+2<len(state.data.indices); i+=3 {
							a:=state.data.vertices[state.data.indices[i]].position; b:=state.data.vertices[state.data.indices[i+1]].position; c:=state.data.vertices[state.data.indices[i+2]].position
							triangle:=rl.GetRayCollisionTriangle(local_ray,a,b,c)
							if triangle.hit && (!hit.hit || triangle.distance<hit.distance) {hit=triangle}
						}
					}
				}
			}
		}
		if has_sphere {
			sphere_hit:=rl.GetRayCollisionSphere(local_ray,{},sphere.radius)
			if sphere_hit.hit && (!hit.hit || sphere_hit.distance<hit.distance) {hit=sphere_hit}
		}
		if !hit.hit {continue}
		point:=rl.Vector3Transform(hit.point,pose_matrix)
		delta:=point-ray.position
		distance:=delta.x*ray.direction.x+delta.y*ray.direction.y+delta.z*ray.direction.z
		if distance<0 || distance>length || (found && (distance>result.distance || (distance==result.distance && entity>=result.entity))) {continue}
		// Inverse-transpose retains perpendicularity under nonuniform scale.
		normal,normal_ok:=scene_query_unit(rl.Vector3Transform(hit.normal,rl.MatrixTranspose(inverse)))
		if !normal_ok {continue}
		if rl.Vector3DotProduct(normal,ray.direction)>0 {normal=-normal}
		result={entity=entity,point=point,distance=distance,normal=normal}; found=true
	}
	return result,found
}

// Exact directional extents of supported rendered geometry in this subtree.
// Direction is normalized; distances are world units relative to origin.
// This uses the same composed TRS as rendering and requires no GPU context.
// include_disabled allows authoring tools to measure hidden source geometry.
scene_projected_bounds :: proc(world:^ecs.World,root:ecs.Entity,origin,direction:[3]f32,include_disabled:bool=false) -> (minimum,maximum:f32,found:bool) {
	if world==nil || !ecs.is_alive(world,root) || !scene_query_vector_valid(origin) {return 0,0,false}
	axis,valid:=scene_query_unit(direction); if !valid {return 0,0,false}
	for entity in world.entities {
		if !scene_query_in_subtree(world,entity,root) || (!include_disabled && !ecs.is_enabled(world,entity)) {continue}
		mesh,has_mesh:=ecs.get_mesh_renderer(world,entity); sphere,has_sphere:=ecs.get_sphere_renderer(world,entity)
		if !has_mesh && !has_sphere {continue}
		pose,pose_ok:=ecs.terrain_transform(world,entity); if !pose_ok {continue}
		rotation:=rotation_quaternion(pose)
		transform:=rl.MatrixTranslate(pose.position[0],pose.position[1],pose.position[2])*rl.QuaternionToMatrix(rotation)*rl.MatrixScale(pose.scale[0],pose.scale[1],pose.scale[2])
		if has_mesh {
			switch mesh.primitive {
			case "cube","plane","quad":
				for i in 0..<8 {
					corner:=[3]f32{0.5 if i&1!=0 else -0.5,0.5 if i&2!=0 else -0.5,0.5 if i&4!=0 else -0.5}
					if mesh.primitive=="plane" {corner[1]=0}
					if mesh.primitive=="quad" {corner[2]=0}
					point:=rl.Vector3Transform(corner,transform)
					projection:=rl.Vector3DotProduct(point-origin,axis)
					if !found {minimum,maximum,found=projection,projection,true}
					else {minimum=min(minimum,projection); maximum=max(maximum,projection)}
				}
			case "static":
				if state,ok:=world.static_meshes[entity]; ok {
					for v in state.data.vertices {
						point:=rl.Vector3Transform(v.position,transform)
						projection:=rl.Vector3DotProduct(point-origin,axis)
						if !found {minimum,maximum,found=projection,projection,true}
						else {minimum=min(minimum,projection); maximum=max(maximum,projection)}
					}
				}
			}
		}
		if has_sphere {
			// A nonuniformly scaled sphere is an ellipsoid. Its exact support
			// distance is the length of the scaled local query direction.
			local_axis:=rl.Vector3RotateByQuaternion(axis,1/rotation)
			radius:=sphere.radius*rl.Vector3Length(local_axis*pose.scale)
			center:=rl.Vector3DotProduct(pose.position-origin,axis)
			if !found {minimum,maximum,found=center-radius,center+radius,true}
			else {minimum=min(minimum,center-radius); maximum=max(maximum,center+radius)}
		}
	}
	return
}
