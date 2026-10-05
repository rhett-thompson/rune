package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "rune:ecs"
import "rune:geometry"

main :: proc() {
	volume:=geometry.Volume{size={4,1,4},spacing=1,origin={-2,-1,-2},cells=make([]u8,16)}
	defer delete(volume.cells)
	geometry.fill_box(volume,{0,0,0},{4,1,4},1)
	colors:=[2][4]u8{{},{220,220,220,255}}
	mesh,ok:=geometry.surface(volume,colors[:]); assert(ok)
	defer geometry.destroy_mesh(&mesh)
	assert(len(mesh.indices)==36 && len(mesh.vertices)==24,"a solid rectangular volume merges to six faces")
	for i:=0; i<len(mesh.indices); i+=3 {
		a,b,c:=mesh.vertices[mesh.indices[i]],mesh.vertices[mesh.indices[i+1]],mesh.vertices[mesh.indices[i+2]]
		assert(linalg.dot(linalg.cross(b.position-a.position,c.position-a.position),a.normal)>0,"outward winding")
	}
	world:=ecs.init(); defer ecs.destroy(&world)
	registry:=ecs.init_registry(); defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	entity:=ecs.create_entity(&world)
	assert(ecs.add(&world,&registry,entity,ecs.Transform{scale={1,1,1}}))
	assert(ecs.set_static_mesh(&world,entity,mesh))
	assert(!ecs.add(&world,&registry,entity,ecs.BoxCollider{size={1,1,1},is_static=true}),"exclusive native body ownership")
	hit,found:=ecs.physics_3d_raycast(&world,{0,3,0},{0,-5,0})
	assert(found && hit.entity==entity && hit.component=="StaticMesh" && math.abs(hit.point[1])<0.001)
	actor:=ecs.create_entity(&world)
	assert(ecs.add(&world,&registry,actor,ecs.Transform{position={0,0.03,0},scale={1,1,1}}))
	assert(ecs.add(&world,&registry,actor,ecs.default_character_controller_3d()))
	for _ in 0..<60 {ecs.physics_3d_update(&world,1.0/60)}
	state,_:=ecs.get_character_controller_3d_state(&world,actor)
	assert(state.grounded,"motor grounds on runtime triangle mesh")
	assert(ecs.set_enabled(&world,entity,false))
	_,found=ecs.physics_3d_raycast(&world,{0,3,0},{0,-5,0}); assert(!found)
	assert(ecs.set_enabled(&world,entity,true))
	_,found=ecs.physics_3d_raycast(&world,{0,3,0},{0,-5,0}); assert(found)
	pose,_:=ecs.get_transform(&world,entity); pose.position[1]=2
	assert(ecs.set_transform(&world,entity,pose))
	hit,found=ecs.physics_3d_raycast(&world,{0,4,0},{0,-5,0}); assert(found && math.abs(hit.point[1]-2)<0.001)
	bad:=mesh; bad.indices=make([dynamic]u32); defer delete(bad.indices)
	append(&bad.indices,0,0,0)
	assert(!ecs.set_static_mesh(&world,entity,bad),"invalid replacement rejected")
	hit,found=ecs.physics_3d_raycast(&world,{0,4,0},{0,-5,0}); assert(found && math.abs(hit.point[1]-2)<0.001,"old geometry retained")
	// Detailed visuals and simplified collision have independent lifetimes.
	collision: geometry.Mesh
	append(&collision.vertices,..mesh.vertices[:]); append(&collision.indices,..mesh.indices[:])
	defer geometry.destroy_mesh(&collision)
	for &vertex in collision.vertices {vertex.position[1]+=1}
	assert(ecs.set_static_mesh(&world,entity,mesh,&collision))
	hit,found=ecs.physics_3d_raycast(&world,{0,4,0},{0,-5,0}); assert(found && math.abs(hit.point[1]-3)<0.001,"queries use the supplied collision mesh")
	assert(world.static_meshes[entity].data.vertices[0].position==mesh.vertices[0].position,"renderer retains original geometry")
	for &vertex in collision.vertices {vertex.position[1]+=10}
	hit,found=ecs.physics_3d_raycast(&world,{0,4,0},{0,-5,0}); assert(found && math.abs(hit.point[1]-3)<0.001,"native collision owns a copy")
	assert(!ecs.set_static_mesh(&world,entity,mesh,&bad),"invalid collision replacement rejected")
	hit,found=ecs.physics_3d_raycast(&world,{0,4,0},{0,-5,0}); assert(found && math.abs(hit.point[1]-3)<0.001,"failed collision replacement retains old body")
	// Surface dressing uses the same render resource ownership without physics.
	assert(ecs.set_static_mesh(&world,entity,mesh,collidable=false))
	assert(world.static_meshes[entity].mesh==nil && len(world.static_meshes[entity].data.indices)>0)
	_,found=ecs.physics_3d_raycast(&world,{0,4,0},{0,-5,0},{layers=~u64(0),ignore=actor}); assert(!found,"render-only replacement removes previous collision")
	assert(!ecs.set_static_mesh(&world,entity,bad,collidable=false),"invalid render-only replacement rejected")
	assert(!ecs.set_static_mesh(&world,entity,mesh,&collision,collidable=false),"conflicting collision options rejected")
	assert(ecs.set_enabled(&world,entity,false) && ecs.set_enabled(&world,entity,true))
	_,found=ecs.physics_3d_raycast(&world,{0,4,0},{0,-5,0},{layers=~u64(0),ignore=actor}); assert(!found,"activation does not create a render-only body")
	assert(ecs.set_static_mesh(&world,entity,mesh))
	hit,found=ecs.physics_3d_raycast(&world,{0,4,0},{0,-5,0},{layers=~u64(0),ignore=actor}); assert(found && math.abs(hit.point[1]-2)<0.001,"collision can be restored")
	assert(ecs.set_static_mesh(&world,entity,mesh,collidable=false))
	// CPU data is copied; later caller edits never alter the installed mesh.
	mesh.vertices[0].position[0]=99
	assert(world.static_meshes[entity].data.vertices[0].position[0]!=99)
	assert(ecs.destroy_entity(&world,entity))
	_,found=ecs.physics_3d_raycast(&world,{0,4,0},{0,-5,0}); assert(!found && len(world.static_meshes)==0)
	// Mesh tread edges must not turn a .25m riser into an unwalkable slope.
	stairs:=geometry.Volume{size={36,12,8},spacing=0.25,origin={0,-0.25,0},cells=make([]u8,36*12*8)}
	defer delete(stairs.cells)
	geometry.fill_box(stairs,{0,0,0},{36,1,8},1)
	for step in 0..<8 {geometry.fill_box(stairs,{8+step*2,step,0},{10+step*2,step+2,8},1)}
	geometry.fill_box(stairs,{24,7,0},{36,9,8},1)
	stair_mesh,stair_ok:=geometry.surface(stairs,colors[:]); assert(stair_ok)
	defer geometry.destroy_mesh(&stair_mesh)
	stair_entity:=ecs.create_entity(&world)
	assert(ecs.add(&world,&registry,stair_entity,ecs.Transform{scale={1,1,1}}))
	assert(ecs.set_static_mesh(&world,stair_entity,stair_mesh))
	actor_pose,_:=ecs.get_transform(&world,actor); actor_pose.position={1.5,0.025,1}
	assert(ecs.set_transform(&world,actor,actor_pose))
	for _ in 0..<10 {ecs.physics_3d_update(&world,1.0/60)}
	ecs.character_controller_3d_move(&world,actor,{1,0})
	for _ in 0..<70 {ecs.physics_3d_update(&world,1.0/60)}
	actor_pose,_=ecs.get_transform(&world,actor)
	assert(actor_pose.position[0]>6 && actor_pose.position[1]>1.95,"capsule climbs merged triangle-mesh stairs")
	// Independently owned mesh bodies meet flush across chunk boundaries.
	{
		w:=ecs.init(); defer ecs.destroy(&w)
		r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
		chunks,chunks_ok:=geometry.surface_chunks(volume,colors[:],{2,1,2}); assert(chunks_ok); defer geometry.destroy_mesh_chunks(&chunks)
		for chunk in chunks {
			e:=ecs.create_entity(&w); assert(ecs.add(&w,&r,e,ecs.Transform{scale={1,1,1}}) && ecs.set_static_mesh(&w,e,chunk.mesh))
		}
		a:=ecs.create_entity(&w); assert(ecs.add(&w,&r,a,ecs.Transform{position={-1.5,0.025,0.2},scale={1,1,1}}) && ecs.add(&w,&r,a,ecs.default_character_controller_3d()))
		for _ in 0..<20 {ecs.physics_3d_update(&w,1.0/60)}
		for direction in ([2]f32{1,-1}) {
			ecs.character_controller_3d_move(&w,a,{direction,0})
			for _ in 0..<36 {ecs.physics_3d_update(&w,1.0/60); p,_:=ecs.get_transform(&w,a); s,_:=ecs.get_character_controller_3d_state(&w,a); assert(s.grounded && abs(p.position[1])<0.08,"no drop or hop at independent collision seams")}
			p,_:=ecs.get_transform(&w,a); assert(p.position[0]*direction>0.25,"capsule reaches the opposite side of the seam")
		}
	}
	ecs.destroy(&world); ecs.destroy(&world)
	fmt.println("PASS greedy surfaces, winding, static mesh ownership, separate collision, queries, grounding, activation, edits, replacement, mesh stairs, chunk seams, cleanup")
}
