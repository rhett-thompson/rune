package render

import "core:testing"
import "rune:ecs"
import "rune:geometry"
import rl "vendor:raylib"

@(test)
rendered_sphere_batch_keeps_independent_hits_and_refreshes_edited_geometry :: proc(t:^testing.T) {
	w:=ecs.init();defer ecs.destroy(&w)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
	root:=ecs.create_entity(&w)
	assert(ecs.add(&w,&r,root,ecs.Transform{position={3,0,10},rotation={0,90,0},scale={-2,1,1}}))
	box:=ecs.create_entity(&w);assert(ecs.set_parent(&w,box,root))
	assert(ecs.add(&w,&r,box,ecs.Transform{scale={2,4,2}}) && ecs.add(&w,&r,box,ecs.MeshRenderer{primitive="cube"}))
	requests:=[6]Scene_Sphere_Cast_3D{
		{origin={3,0,0},translation={0,0,20},radius=0.5},
		{origin={3,0,20},translation={0,0,-20},radius=0.5},
		{origin={1.75,0,0},translation={0,0,20},radius=0.5},
		{origin={1.75,0,0},translation={0,0,20},radius=0},
		{origin={3,0,10},translation={0,0,20},radius=0.5},
		{origin={3,0,0},translation={0,0,20},radius=0.5,ignore=box},
	}
	results:[6]Scene_Sphere_Cast_Result_3D
	scene_sphere_cast_batch_3d(&w,requests[:],results[:])
	testing.expect(t,results[0].found && abs(results[0].hit.distance-7.5)<0.02)
	testing.expect(t,results[1].found && abs(results[1].hit.distance-7.5)<0.02,"Opposite sweeps keep independent nearest distances")
	testing.expect(t,results[2].found && !results[3].found,"A grazing sphere blocks while a zero-radius ray stays clear")
	testing.expect(t,results[4].found && results[4].hit.distance==0 && !results[5].found)
	pose,_:=ecs.get_transform(&w,root);pose.position[2]=15;ecs.set_transform(&w,root,pose)
	scene_sphere_cast_batch_3d(&w,requests[:],results[:])
	testing.expect(t,results[0].found && abs(results[0].hit.distance-12.5)<0.02,"A batch sees parent edits without a stale snapshot")
	ignored:=[1]ecs.Entity{root}
	scene_sphere_cast_batch_3d(&w,requests[:],results[:],ignored_subtrees=ignored[:])
	for result in results {testing.expect(t,!result.found,"Excluded ancestors apply to every request and reused results are cleared")}
	ecs.set_enabled(&w,root,false)
	scene_sphere_cast_batch_3d(&w,requests[:],results[:])
	for result in results {testing.expect(t,!result.found,"Disabled parents are observed on the next batch")}
}

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

@(private="file")
Sphere_Cast_Bounds_Probe :: struct {
	bounds: map[ecs.Entity]rl.BoundingBox,
	visits: map[ecs.Entity]int,
}

@(private="file")
sphere_cast_probe_bounds :: proc(data: rawptr, world: ^ecs.World, entity: ecs.Entity) -> (rl.BoundingBox, bool) {
	probe := (^Sphere_Cast_Bounds_Probe)(data)
	probe.visits[entity] += 1
	bounds, found := probe.bounds[entity]
	return bounds, found
}

@(test)
rendered_sphere_batch_keeps_hierarchy_and_custom_bounds_semantics :: proc(t: ^testing.T) {
	w := ecs.init(); defer ecs.destroy(&w)
	r := ecs.init_registry(); defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	model := ecs.create_entity(&w)
	root := ecs.create_entity(&w)
	assert(ecs.add(&w, &r, root, ecs.Transform{position={3,0,10}, rotation={0,90,0}, scale={2,1,1}}))
	group := ecs.create_entity(&w)
	assert(ecs.set_parent(&w, group, root) && ecs.set_parent(&w, model, group))
	compound := ecs.create_entity(&w)
	assert(ecs.set_parent(&w, compound, group))
	assert(ecs.add(&w, &r, compound, ecs.Transform{position={0,0,5}, scale={1,1,1}}))
	assert(ecs.add(&w, &r, compound, ecs.MeshRenderer{primitive="cube"}))
	assert(ecs.add(&w, &r, compound, ecs.SphereRenderer{radius=1}))
	disabled, hidden, excluded, ignored := ecs.create_entity(&w), ecs.create_entity(&w), ecs.create_entity(&w), ecs.create_entity(&w)
	assert(ecs.set_parent(&w, disabled, root) && ecs.set_parent(&w, hidden, disabled) && ecs.set_enabled(&w, disabled, false))
	assert(ecs.set_parent(&w, excluded, root) && ecs.set_parent(&w, ignored, excluded))
	probe := Sphere_Cast_Bounds_Probe{make(map[ecs.Entity]rl.BoundingBox), make(map[ecs.Entity]int)}
	defer {delete(probe.bounds); delete(probe.visits)}
	for entity in ([5]ecs.Entity{root, model, compound, hidden, ignored}) {probe.bounds[entity] = {{-2,-2,-2},{2,2,2}}}
	exclusions := [1]ecs.Entity{excluded}
	requests := [4]Scene_Sphere_Cast_3D{
		{origin={3,0,0}, translation={0,0,20}, radius=0.25, ignore=root},
		{origin={8,0,0}, translation={0,0,20}, radius=0.25},
		{origin={3,0,10}, translation={0,0,20}, radius=0.25},
		{origin={3,0,0}, translation={0,0,20}, ignore=root},
	}
	results: [len(requests)]Scene_Sphere_Cast_Result_3D
	scene_sphere_cast_batch_3d(&w, requests[:], results[:], sphere_cast_probe_bounds, &probe, exclusions[:])
	testing.expect(t, results[0].found && results[0].hit.entity == model && abs(results[0].hit.distance-5.75) < 0.02,
		"custom bounds can supply geometry beneath a transformless parent and an exactly ignored entity")
	testing.expect(t, results[1].found && results[1].hit.entity == compound && abs(results[1].hit.distance-7.75) < 0.02,
		"compound bounds preserve sphere priority over a cube and custom model")
	testing.expect(t, results[2].found && results[2].hit.entity == model && results[2].hit.distance == 0,
		"the lower entity ID wins a tied initial overlap even when its parent is visited first")
	testing.expect(t, results[3].found && results[3].hit.entity == model && abs(results[3].hit.distance-6) < 0.02,
		"zero radius keeps the ordinary ray's contact")
	testing.expect(t, probe.visits[root] == 1 && probe.visits[group] == 2 && probe.visits[model] == 2 && probe.visits[compound] == 2,
		"the positive-radius traversal shares one callback per entity and the ray keeps its own exact-ignore rule")
	for entity in ([4]ecs.Entity{disabled, hidden, excluded, ignored}) {
		testing.expect(t, probe.visits[entity] == 0, "bounds callbacks skip disabled and excluded subtrees")
	}
}
