package ecs

import "rune:geometry"
import b3 "vendor:box3d"

// Runtime-only geometry. World owns CPU/native resources; the rendering bridge
// owns its GPU copy. Removing the entity or replacing the World releases both.
Static_Mesh :: struct {
	data: geometry.Mesh,
	mesh: ^b3.MeshData,
	revision: u64,
	body_transform: Transform,
	body_layers: u64,
}

// Optional collision geometry lets callers simplify physics independently of
// visible detail. collidable=false installs only render data (e.g. surface paint).
// Both inputs remain caller-owned; invalid replacements are atomic.
set_static_mesh :: proc(world: ^World, entity: Entity, data: geometry.Mesh, collision: ^geometry.Mesh = nil, collidable := true) -> bool {
	if !is_alive(world,entity) || !geometry.valid(data) {return false}
	if !collidable && collision!=nil {return false}
	shape_data:=data
	if collision!=nil {if !geometry.valid(collision^) {return false}; shape_data=collision^}
	if _,ok := terrain_transform(world,entity); !ok {return false}
	for name in ([6]string{"Terrain","RigidBody3D","BoxCollider","SphereCollider","CharacterController3D","CharacterController"}) {
		if has_component_data(world,entity,name) {return false}
	}
	mesh: ^b3.MeshData
	if collidable {
		// Weld positions before identifying collision edges, independently of the
		// split render normals/colors. Box3D copies input buffers in CreateMesh.
		vertices := make([dynamic]b3.Vec3)
		defer delete(vertices)
		indices := make([]i32,len(shape_data.indices))
		defer delete(indices)
		lookup := make(map[[3]f32]i32)
		defer delete(lookup)
		for index,i in shape_data.indices {
			p := shape_data.vertices[index].position
			id,found := lookup[p]
			if !found {id=i32(len(vertices)); lookup[p]=id; append(&vertices,b3.Vec3{p[0],p[1],p[2]})}
			indices[i]=id
		}
		mesh = b3.CreateMesh({vertices=raw_data(vertices),indices=raw_data(indices),vertexCount=i32(len(vertices)),triangleCount=i32(len(indices)/3),identifyEdges=true,useMedianSplit=true},nil,0)
		if mesh==nil {return false}
	}
	copy_data: geometry.Mesh
	append(&copy_data.vertices,..data.vertices[:]); append(&copy_data.indices,..data.indices[:])
	remove_static_mesh(world,entity)
	world.static_mesh_revision += 1
	world.static_meshes[entity] = {data=copy_data,mesh=mesh,revision=world.static_mesh_revision}
	world.physics_3d.needs_sync=true
	return true
}

remove_static_mesh :: proc(world: ^World, entity: Entity) {
	state,found := world.static_meshes[entity]
	if !found {return}
	physics_3d_remove_entity(world,entity)
	if state.mesh!=nil {b3.DestroyMesh(state.mesh)}
	geometry.destroy_mesh(&state.data)
	delete_key(&world.static_meshes,entity)
}

destroy_static_meshes :: proc(world: ^World) {
	for entity in world.static_meshes {remove_static_mesh(world,entity)}
	delete(world.static_meshes); world.static_meshes=nil
}

sync_static_mesh_bodies :: proc(world: ^World) {
	for entity,&state in world.static_meshes {
		if state.mesh==nil {continue}
		t,valid := terrain_transform(world,entity)
		if !is_enabled(world,entity) || !valid {physics_3d_remove_entity(world,entity); continue}
		layers,_ := entity_layer_mask(world,entity)
		if _,exists := world.box3d_bodies[entity]; exists {
			if state.body_transform==t && state.body_layers==layers {continue}
			physics_3d_remove_entity(world,entity)
		}
		native := create_box3d_body_id(world,{body_type="static"},t)
		shape := b3.CreateMeshShape(native,create_box3d_shape_def(world,entity,0.8,0,0),state.mesh,{t.scale[0],t.scale[1],t.scale[2]})
		world.physics_3d.shapes[b3.StoreShapeId(shape)]={entity,"StaticMesh"}
		world.box3d_bodies[entity]=native
		state.body_transform=t; state.body_layers=layers
	}
}
