package render

import "core:math"
import "rune:ecs"
import b3 "vendor:box3d"
import rl "vendor:raylib"

// Distance is travel of the sphere's centre; point lies on the contacted surface.
// Render-only primitives and CPU mesh triangles need no native physics bodies.
// Imported models and scaled spheres use conservative bounds.
scene_sphere_cast_3d :: proc(world:^ecs.World,origin,translation:[3]f32,radius:f32,ignore:ecs.Entity=0,model_bounds:Scene_Model_Bounds_3D=nil,bounds_data:rawptr=nil,ignored_subtrees:[]ecs.Entity=nil,static_bounds:Scene_Static_Mesh_Bounds_3D=nil) -> (Scene_Ray_Hit_3D,bool) {
	if world==nil || !pick_3d_vector_valid(origin) || !pick_3d_vector_valid(translation) || !(radius>=0) || math.is_inf(radius) {return {},false}
	length:=rl.Vector3Length(translation)
	if !(length>0) || math.is_inf(length) {return {},false}
	if radius==0 {return scene_raycast_3d(world,origin,translation,ignore,model_bounds,bounds_data,ignored_subtrees,static_bounds)}
	result:Scene_Ray_Hit_3D
	found:=false
	for entity in world.entities {
		if entity==ignore || !ecs.is_enabled(world,entity) {continue}
		excluded:=false
		for root in ignored_subtrees {if pick_3d_in_subtree(world,entity,root) {excluded=true;break}}
		if excluded {continue}
		mesh,has_mesh:=ecs.get_mesh_renderer(world,entity)
		sphere,has_sphere:=ecs.get_sphere_renderer(world,entity)
		bounds:rl.BoundingBox
		has_bounds:=false
		if model_bounds!=nil {bounds,has_bounds=model_bounds(bounds_data,world,entity);has_bounds=has_bounds && pick_3d_bounds_valid(bounds)}
		if !has_mesh && !has_sphere && !has_bounds {continue}
		pose:=ecs.world_transform_3d(world,entity)
		if !pick_3d_vector_valid(pose.position) || !pick_3d_vector_valid(pose.rotation) || !pick_3d_vector_valid(pose.scale) {continue}
		if pose.scale[0]==0 || pose.scale[1]==0 || pose.scale[2]==0 {continue}
		rotation:=pose.rotation*f32(math.PI/180)
		pose_matrix:=rl.MatrixTranslate(pose.position[0],pose.position[1],pose.position[2])*rl.QuaternionToMatrix(rl.QuaternionFromEuler(rotation[0],rotation[1],rotation[2]))*rl.MatrixScale(pose.scale[0],pose.scale[1],pose.scale[2])
		inverse:=rl.MatrixInvert(pose_matrix)
		local_origin:=rl.Vector3Transform(origin,inverse)
		local_delta:=(rl.Vector3Transform(origin+translation,inverse)-local_origin)*(result.distance/length if found else 1)
		padding:=[3]f32{radius/abs(pose.scale[0]),radius/abs(pose.scale[1]),radius/abs(pose.scale[2])}
		triangles:=false
		data:ecs.Static_Mesh
		if has_mesh {
			switch mesh.primitive {
			case "cube","plane","quad":
				bounds={{-0.5,-0.5,-0.5},{0.5,0.5,0.5}};has_bounds=true
				if mesh.primitive=="plane" {bounds.min[1],bounds.max[1]=0,0}
				if mesh.primitive=="quad" {bounds.min[2],bounds.max[2]=0,0}
			case "static":
				data,triangles=world.static_meshes[entity]
				if triangles && len(data.data.vertices)>0 {
					cached:=false
					if static_bounds!=nil {bounds,cached=static_bounds(bounds_data,world,entity,data.revision);cached=cached && pick_3d_bounds_valid(bounds)}
					if !cached {
						bounds={data.data.vertices[0].position,data.data.vertices[0].position}
						for vertex in data.data.vertices {for axis in 0..<3 {bounds.min[axis]=min(bounds.min[axis],vertex.position[axis]);bounds.max[axis]=max(bounds.max[axis],vertex.position[axis])}}
					}
					has_bounds=true
				}
			}
		}
		if has_sphere {bounds={-[3]f32{1,1,1}*sphere.radius,[3]f32{1,1,1}*sphere.radius};has_bounds=true}
		if !has_bounds || !sphere_cast_bounds_3d(bounds,local_origin,local_delta,padding) {continue}
		contact:b3.CastOutput
		if triangles {
			contact=sphere_cast_mesh_3d(ecs.static_mesh_query_acceleration(world,entity),pose_matrix,origin,translation,radius,local_origin,local_delta,padding)
		} else {
			points:[8]b3.Vec3
			for i in 0..<8 {
				corner:=[3]f32{bounds.max[0] if i&1!=0 else bounds.min[0],bounds.max[1] if i&2!=0 else bounds.min[1],bounds.max[2] if i&4!=0 else bounds.min[2]}
				p:=rl.Vector3Transform(corner,pose_matrix)-origin;points[i]={p[0],p[1],p[2]}
			}
			contact=sphere_cast_proxy_3d(points[:],translation,radius)
		}
		if !contact.hit {continue}
		distance:=contact.fraction*length
		if found && (distance>result.distance || (distance==result.distance && entity>=result.entity)) {continue}
		result={entity=entity,distance=distance,point=origin+[3]f32{contact.point.x,contact.point.y,contact.point.z},normal={contact.normal.x,contact.normal.y,contact.normal.z}};found=true
	}
	return result,found
}

@(private)
sphere_cast_mesh_3d :: proc(mesh:^b3.MeshData,pose_matrix:rl.Matrix,origin,translation:[3]f32,radius:f32,local_origin,local_delta,padding:[3]f32) -> (contact:b3.CastOutput) {
	if mesh==nil {return}
	node_pointer,nodes_ok:=b3.GetMeshNodes(mesh).(^b3.MeshNode)
	vertex_pointer,vertices_ok:=b3.GetMeshVertices(mesh).(^b3.Vec3)
	triangle_pointer,triangles_ok:=b3.GetMeshTriangles(mesh).(^b3.MeshTriangle)
	if !nodes_ok || !vertices_ok || !triangles_ok {return}
	nodes:=([^]b3.MeshNode)(node_pointer)
	vertices:=([^]b3.Vec3)(vertex_pointer)
	triangles:=([^]b3.MeshTriangle)(triangle_pointer)
	// A binary BVH needs at most depth+1 pending nodes, not one per triangle.
	stack:=make([dynamic]u32,0,int(mesh.treeHeight)+2,context.temp_allocator)
	append(&stack,0)
	for len(stack)>0 {
		index:=pop(&stack)
		node:=nodes[index]
		bounds:=rl.BoundingBox{{node.lowerBound.x,node.lowerBound.y,node.lowerBound.z},{node.upperBound.x,node.upperBound.y,node.upperBound.z}}
		if !sphere_cast_bounds_3d(bounds,local_origin,local_delta,padding) {continue}
		if node.data.asLeaf.type!=3 {append(&stack,index+1,index+u32(node.data.asNode.childOffset));continue}
		for j in 0..<int(node.data.asLeaf.triangleCount) {
			triangle:=triangles[node.triangleOffset+u32(j)]
			points:[3]b3.Vec3
			for vertex_id,k in ([3]i32{triangle.index1,triangle.index2,triangle.index3}) {
				v:=vertices[vertex_id]
				p:=rl.Vector3Transform({v.x,v.y,v.z},pose_matrix)-origin
				points[k]={p[0],p[1],p[2]}
			}
			hit:=sphere_cast_proxy_3d(points[:],translation,radius)
			if hit.hit && (!contact.hit || hit.fraction<contact.fraction) {contact=hit}
		}
	}
	return
}

@(private)
sphere_cast_bounds_3d :: proc(bounds:rl.BoundingBox,origin,delta,padding:[3]f32) -> bool {
	low,high:=f32(0),f32(1)
	for axis in 0..<3 {
		minimum,maximum:=bounds.min[axis]-padding[axis],bounds.max[axis]+padding[axis]
		if abs(delta[axis])<1e-12 {if origin[axis]<minimum || origin[axis]>maximum {return false};continue}
		a,b:=(minimum-origin[axis])/delta[axis],(maximum-origin[axis])/delta[axis]
		low=max(low,min(a,b));high=min(high,max(a,b))
		if low>high {return false}
	}
	return true
}

@(private)
sphere_cast_proxy_3d :: proc(points:[]b3.Vec3,translation:[3]f32,radius:f32) -> b3.CastOutput {
	centre:=b3.Vec3{}
	shape:=b3.ShapeProxy{points=raw_data(points),count=i32(len(points))}
	ball:=b3.ShapeProxy{points=&centre,count=1,radius=radius}
	cache:b3.SimplexCache
	distance:=b3.ShapeDistance({proxyA=shape,proxyB=ball,transform=b3.Transform_identity,useRadii=true},&cache,nil,0)
	if distance.distance<=0.00001 {
		normal:=rl.Vector3Normalize(-translation)
		return {hit=true,point=distance.pointA,normal={normal[0],normal[1],normal[2]},fraction=0}
	}
	return b3.ShapeCast({proxyA=shape,proxyB=ball,transform=b3.Transform_identity,translationB={translation[0],translation[1],translation[2]},maxFraction=1})
}
