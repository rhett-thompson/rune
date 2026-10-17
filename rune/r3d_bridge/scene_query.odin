package r3d_bridge

import "core:math"
import "rune:ecs"
import "rune:render"
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

// Query already imported assets only. The cached local AABB is a conservative
// static-model surface; queries never import models or create GPU resources.
scene_query_model_bounds :: proc(world:^ecs.World,entity:ecs.Entity,bridge:^Context) -> (rl.BoundingBox,bool) {
	if bridge==nil {return {},false}
	renderer,has_model:=ecs.get_model_renderer(world,entity)
	if !has_model {return {},false}
	asset,cached:=bridge.models[renderer.model]
	if !cached || asset.model.meshCount<=0 {return {},false}
	bounds:=asset.model.aabb
	if !scene_query_vector_valid(bounds.min) || !scene_query_vector_valid(bounds.max) {return {},false}
	for axis in 0..<3 {if bounds.min[axis]>bounds.max[axis] {return {},false}}
	return bounds,true
}

// Picks supported rendered geometry along a bounded world-space segment.
// The shared CPU query does not require a GPU; the optional bridge supplies
// already imported static model bounds and never loads an asset during a query.
scene_raycast :: proc(world: ^ecs.World, origin, translation: [3]f32, ignore: ecs.Entity=0, bridge: ^Context=nil, ignored_subtrees:[]ecs.Entity=nil) -> (Scene_Ray_Hit,bool) {
	hit,ok:=render.scene_raycast_3d(world,origin,translation,ignore,scene_query_bridge_bounds,bridge,ignored_subtrees,scene_query_bridge_static_bounds)
	return Scene_Ray_Hit{entity=hit.entity,point=hit.point,distance=hit.distance,normal=hit.normal},ok
}

@(private)
scene_query_bridge_bounds :: proc(data: rawptr,world:^ecs.World,entity:ecs.Entity) -> (rl.BoundingBox,bool) {
	return scene_query_model_bounds(world,entity,cast(^Context)data)
}

@(private)
scene_query_bridge_static_bounds :: proc(data: rawptr,world:^ecs.World,entity:ecs.Entity,revision:u64) -> (rl.BoundingBox,bool) {
	bridge:=cast(^Context)data
	if bridge==nil {return {},false}
	cache,present:=bridge.static_meshes[entity]
	if !present || bridge.static_mesh_generation!=world.generation || cache.revision!=revision {return {},false}
	return cache.mesh.aabb,true
}

// Directional extents of supported rendered geometry in this subtree.
// Direction is normalized; distances are world units relative to origin.
// This uses the same composed TRS as rendering and requires no GPU context.
// include_disabled allows authoring tools to measure hidden source geometry.
// Primitive/static mesh support is exact. Imported models require a bridge
// with a cached asset and conservatively project its local AABB corners.
scene_projected_bounds :: proc(world:^ecs.World,root:ecs.Entity,origin,direction:[3]f32,include_disabled:bool=false,bridge:^Context=nil) -> (minimum,maximum:f32,found:bool) {
	if world==nil || !ecs.is_alive(world,root) || !scene_query_vector_valid(origin) {return 0,0,false}
	axis,valid:=scene_query_unit(direction); if !valid {return 0,0,false}
	for entity in world.entities {
		if !scene_query_in_subtree(world,entity,root) || (!include_disabled && !ecs.is_enabled(world,entity)) {continue}
		mesh,has_mesh:=ecs.get_mesh_renderer(world,entity); sphere,has_sphere:=ecs.get_sphere_renderer(world,entity)
		model_bounds,has_model:=scene_query_model_bounds(world,entity,bridge)
		if !has_mesh && !has_sphere && !has_model {continue}
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
		if has_model {
			for i in 0..<8 {
				corner:=[3]f32{model_bounds.max[0] if i&1!=0 else model_bounds.min[0],model_bounds.max[1] if i&2!=0 else model_bounds.min[1],model_bounds.max[2] if i&4!=0 else model_bounds.min[2]}
				point:=rl.Vector3Transform(corner,transform)
				projection:=rl.Vector3DotProduct(point-origin,axis)
				if !found {minimum,maximum,found=projection,projection,true}
				else {minimum=min(minimum,projection); maximum=max(maximum,projection)}
			}
		}
	}
	return
}
