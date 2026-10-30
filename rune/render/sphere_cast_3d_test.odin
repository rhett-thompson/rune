package render

import "core:testing"
import "rune:ecs"
import "rune:geometry"

@(test)
rendered_sphere_cast_stops_at_render_only_boxes_and_respects_width :: proc(t:^testing.T) {
	w:=ecs.init();defer ecs.destroy(&w)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
	root:=ecs.create_entity(&w);assert(ecs.add(&w,&r,root,ecs.Transform{position={3,0,10},rotation={0,90,0},scale={2,1,1}}))
	box:=ecs.create_entity(&w);assert(ecs.set_parent(&w,box,root))
	assert(ecs.add(&w,&r,box,ecs.Transform{scale={2,4,2}}) && ecs.add(&w,&r,box,ecs.MeshRenderer{primitive="cube"}))
	// Hierarchy gives world extents x=[2,4], y=[-2,2], z=[8,12].
	hit,ok:=scene_sphere_cast_3d(&w,{1.75,0,0},{0,0,20},0.5)
	testing.expect(t,ok && hit.entity==box && hit.distance>7.4 && hit.distance<8,"Sphere catches a grazing box that its centreline misses")
	_,ray:=scene_raycast_3d(&w,{1.75,0,0},{0,0,20});testing.expect(t,!ray)
	inside,overlap:=scene_sphere_cast_3d(&w,{3,0,10},{0,0,20},0.5)
	testing.expect(t,overlap && inside.distance==0,"Initial overlaps stop immediately")
	ignored:=[1]ecs.Entity{root}
	_,ok=scene_sphere_cast_3d(&w,{3,0,0},{0,0,20},0.5,ignored_subtrees=ignored[:]);testing.expect(t,!ok)
	ecs.set_enabled(&w,root,false)
	_,ok=scene_sphere_cast_3d(&w,{3,0,0},{0,0,20},0.5);testing.expect(t,!ok)
}

@(test)
rendered_sphere_cast_tests_cpu_triangles_instead_of_solid_mesh_bounds :: proc(t:^testing.T) {
	w:=ecs.init();defer ecs.destroy(&w)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
	entity:=ecs.create_entity(&w)
	assert(ecs.add(&w,&r,entity,ecs.Transform{position={0,0,10},scale={2,1,1}}) && ecs.add(&w,&r,entity,ecs.MeshRenderer{primitive="static"}))
	mesh:geometry.Mesh;defer geometry.destroy_mesh(&mesh)
	for p in ([3][3]f32{{-2,-2,0},{2,-2,0},{-2,2,0}}) {append(&mesh.vertices,geometry.Vertex{position=p,normal={0,0,1},color={255,255,255,255}})}
	append(&mesh.indices,0,1,2)
	assert(ecs.set_static_mesh(&w,entity,mesh,collidable=false))
	hit,ok:=scene_sphere_cast_3d(&w,{-1,-1,0},{0,0,20},0.5)
	testing.expect(t,ok && abs(hit.distance-9.5)<0.02 && abs(hit.point[2]-10)<0.02)
	back,back_ok:=scene_sphere_cast_3d(&w,{-1,-1,20},{0,0,-20},0.5)
	testing.expect(t,back_ok && abs(back.distance-9.5)<0.02,"CPU mesh faces block from either direction")
	_,ok=scene_sphere_cast_3d(&w,{3,1.5,0},{0,0,20},0.1)
	testing.expect(t,!ok,"Empty space within a mesh's AABB stays open")
	_,ok=scene_sphere_cast_3d(&w,{-1,-1,0},{0,0,9},0.5);testing.expect(t,!ok,"The sweep is a bounded segment")
	edge,edge_ok:=scene_sphere_cast_3d(&w,{-4.25,-1,0},{0,0,20},0.5)
	testing.expect(t,edge_ok && edge.distance<10,"Triangle edges block the beam width even when its centre misses")
	inside,overlap:=scene_sphere_cast_3d(&w,{-1,-1,9.75},{0,0,20},0.5)
	testing.expect(t,overlap && inside.distance==0,"An initial triangle overlap blocks instead of tunneling")
}

@(test)
rendered_sphere_cast_mesh_acceleration_follows_replacement_and_bvh_branches :: proc(t:^testing.T) {
	w:=ecs.init();defer ecs.destroy(&w)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
	entity:=ecs.create_entity(&w)
	assert(ecs.add(&w,&r,entity,ecs.default_transform()) && ecs.add(&w,&r,entity,ecs.MeshRenderer{primitive="static"}))
	mesh:geometry.Mesh;defer geometry.destroy_mesh(&mesh)
	for i in 0..<80 {
		x:=f32(i)*5
		base:=u32(len(mesh.vertices))
		for p in ([3][3]f32{{x-1,-1,10},{x+1,-1,10},{x,1,10}}) {append(&mesh.vertices,geometry.Vertex{position=p,normal={0,0,1},color={255,255,255,255}})}
		append(&mesh.indices,base,base+1,base+2)
	}
	assert(ecs.set_static_mesh(&w,entity,mesh,collidable=false))
	for x in ([3]f32{0,195,395}) {
		hit,ok:=scene_sphere_cast_3d(&w,{x,0,0},{0,0,20},0.25)
		testing.expect(t,ok && abs(hit.distance-9.75)<0.02,"Separated BVH branches retain the same precise contacts")
	}
	testing.expect(t,w.static_meshes[entity].query_mesh!=nil && w.static_meshes[entity].mesh==nil,"Query acceleration never adds a physics body")
	for &v in mesh.vertices {v.position[2]=15}
	assert(ecs.set_static_mesh(&w,entity,mesh,collidable=false))
	testing.expect(t,w.static_meshes[entity].query_mesh==nil,"Replacing CPU geometry discards its old query acceleration")
	hit,ok:=scene_sphere_cast_3d(&w,{195,0,0},{0,0,20},0.25)
	testing.expect(t,ok && abs(hit.distance-14.75)<0.02)
	ecs.destroy_entity(&w,entity)
	_,ok=scene_sphere_cast_3d(&w,{195,0,0},{0,0,20},0.25);testing.expect(t,!ok)
}
