package render

import "core:math"
import "rune:assets"
import "rune:ecs"
import rl "vendor:raylib"

Scene_Ray_Hit_3D :: struct {
	entity: ecs.Entity,
	point: [3]f32,
	distance: f32,
	// Unit world-space surface normal, oriented toward the ray origin.
	normal: [3]f32,
}

// A read-only provider of already cached local model bounds. Queries never load
// an asset or acquire renderer resources. bounds_data is borrowed for the call.
Scene_Model_Bounds_3D :: #type proc(data: rawptr, world:^ecs.World, entity:ecs.Entity) -> (rl.BoundingBox,bool)

// Optional acceleration metadata for the current CPU mesh revision.
Scene_Static_Mesh_Bounds_3D :: #type proc(data: rawptr, world:^ecs.World, entity:ecs.Entity, revision:u64) -> (rl.BoundingBox,bool)

@(private)
pick_3d_vector_valid :: proc(value:[3]f32) -> bool {
	for n in value {if math.is_nan(n) || math.is_inf(n) {return false}}
	return true
}

@(private)
pick_3d_unit :: proc(value:[3]f32) -> ([3]f32,bool) {
	if !pick_3d_vector_valid(value) {return {},false}
	length:=rl.Vector3Length(value)
	if length<=0 || math.is_nan(length) || math.is_inf(length) {return {},false}
	return value/length,true
}

@(private)
pick_3d_in_subtree :: proc(world:^ecs.World,entity,root:ecs.Entity) -> bool {
	if root==0 {return false}
	for candidate:=entity; candidate!=0; candidate=world.parents[candidate] {
		if candidate==root {return true}
	}
	return false
}

@(private)
pick_3d_bounds_valid :: proc(bounds:rl.BoundingBox) -> bool {
	if !pick_3d_vector_valid(bounds.min) || !pick_3d_vector_valid(bounds.max) {return false}
	for axis in 0..<3 {if bounds.min[axis]>bounds.max[axis] {return false}}
	return true
}

@(private)
pick_3d_cached_model_bounds :: proc(data: rawptr,world:^ecs.World,entity:ecs.Entity) -> (rl.BoundingBox,bool) {
	manager:=cast(^assets.Asset_Manager)data
	if manager==nil {return {},false}
	renderer,ok:=ecs.get_model_renderer(world,entity)
	if !ok {return {},false}
	return assets.cached_model_bounds(manager,renderer.model)
}

// Picks enabled rendered primitives and runtime CPU meshes without a GPU or R3D
// dependency. Imported models use their last successfully rendered static local
// AABB, published in the asset manager by the owning renderer. Shader effects,
// transparency, terrain, and animated deformation are not evaluated.
scene_pick_3d :: proc(world:^ecs.World,origin,translation:[3]f32,asset_manager:^assets.Asset_Manager=nil) -> (Scene_Ray_Hit_3D,bool) {
	return scene_raycast_3d(world,origin,translation,model_bounds=pick_3d_cached_model_bounds,bounds_data=asset_manager)
}

// Translation is a bounded world-space segment. Cube/plane/quad/sphere geometry
// and static CPU triangles follow the rendered composed hierarchy. A read-only
// bounds callback optionally supplies imported models; no assets are loaded.
// ignore excludes one entity; ignored_subtrees excludes roots and descendants.
scene_raycast_3d :: proc(world: ^ecs.World, origin, translation: [3]f32, ignore: ecs.Entity=0, model_bounds: Scene_Model_Bounds_3D=nil, bounds_data: rawptr=nil, ignored_subtrees:[]ecs.Entity=nil, static_bounds:Scene_Static_Mesh_Bounds_3D=nil) -> (Scene_Ray_Hit_3D,bool) {
	if world==nil {return {},false}
	length:=math.sqrt(translation[0]*translation[0]+translation[1]*translation[1]+translation[2]*translation[2])
	if length<=0 || math.is_nan(length) || math.is_inf(length) {return {},false}
	for value in origin {if math.is_nan(value) || math.is_inf(value) {return {},false}}
	ray:=rl.Ray{position=origin,direction=translation/length}
	result: Scene_Ray_Hit_3D; found:=false
	for entity in world.entities {
		if entity==ignore || !ecs.is_enabled(world,entity) {continue}
		excluded:=false
		for root in ignored_subtrees {if pick_3d_in_subtree(world,entity,root) {excluded=true; break}}
		if excluded {continue}
		mesh,has_mesh:=ecs.get_mesh_renderer(world,entity); sphere,has_sphere:=ecs.get_sphere_renderer(world,entity)
		bounds: rl.BoundingBox; has_model:=false
		if model_bounds!=nil {bounds,has_model=model_bounds(bounds_data,world,entity)}
		if has_model {has_model=pick_3d_bounds_valid(bounds)}
		if !has_mesh && !has_sphere && !has_model {continue}
		pose:=ecs.world_transform_3d(world,entity)
		if !pick_3d_vector_valid(pose.position) || !pick_3d_vector_valid(pose.rotation) || !pick_3d_vector_valid(pose.scale) || pose.scale[0]==0 || pose.scale[1]==0 || pose.scale[2]==0 {continue}
		pose_matrix:=rl.MatrixTranslate(pose.position[0],pose.position[1],pose.position[2])*rl.QuaternionToMatrix(rl.QuaternionFromEuler(pose.rotation[0]*f32(math.PI/180),pose.rotation[1]*f32(math.PI/180),pose.rotation[2]*f32(math.PI/180)))*rl.MatrixScale(pose.scale[0],pose.scale[1],pose.scale[2])
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
					if static_bounds!=nil {
						if supplied,valid:=static_bounds(bounds_data,world,entity,state.revision); valid && pick_3d_bounds_valid(supplied) {bounds=supplied; cached=true}
					}
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
		if has_model {
			model_hit:=rl.GetRayCollisionBox(local_ray,bounds)
			if model_hit.hit && (!hit.hit || model_hit.distance<hit.distance) {hit=model_hit}
		}
		if !hit.hit {continue}
		point:=rl.Vector3Transform(hit.point,pose_matrix)
		delta:=point-ray.position
		distance:=delta.x*ray.direction.x+delta.y*ray.direction.y+delta.z*ray.direction.z
		if distance<0 || distance>length || (found && (distance>result.distance || (distance==result.distance && entity>=result.entity))) {continue}
		// Inverse-transpose retains perpendicularity under nonuniform scale.
		normal,normal_ok:=pick_3d_unit(rl.Vector3Transform(hit.normal,rl.MatrixTranspose(inverse)))
		if !normal_ok {continue}
		if rl.Vector3DotProduct(normal,ray.direction)>0 {normal=-normal}
		result={entity=entity,point=point,distance=distance,normal=normal}; found=true
	}
	return result,found
}
