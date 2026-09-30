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
	ecs.destroy(&world); ecs.destroy(&world)
	fmt.println("PASS greedy surfaces, winding, static mesh ownership, queries, grounding, activation, edits, replacement, mesh stairs, cleanup")
}
