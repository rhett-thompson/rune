package ecs

import "core:encoding/json"
import "core:strings"
import "rune:assets"
import "rune:terrain"
import b3 "vendor:box3d"

Terrain :: struct {
	asset: string,
	collision: bool,
	shadows: bool,
	friction: f32,
}

Terrain_Runtime :: struct {
	data: terrain.Data,
	source: string,
	asset_revision, revision: u64,
	mesh: ^b3.MeshData,
	body_transform: Transform,
	body_layers: u64,
}

default_terrain :: proc() -> Terrain {return {collision=true,shadows=true,friction=0.8}}
terrain_valid :: proc(value: Terrain) -> bool {return value.asset != "" && finite_nonnegative(value.friction)}

terrain_from_json :: proc(data: json.Value) -> (Terrain,bool) {
	if !post_processing_json_shape_valid(data,Terrain) {return {},false}
	result := default_terrain()
	bytes,error := json.marshal(data,allocator=context.temp_allocator)
	if error != nil || json.unmarshal(bytes,&result,allocator=context.temp_allocator) != nil {return {},false}
	return result,terrain_valid(result)
}

get_terrain :: proc(world: ^World, entity: Entity) -> (Terrain,bool) {
	value,found := world.terrains[entity]
	return value,found
}

set_terrain :: proc(world: ^World, entity: Entity, value: Terrain) -> bool {
	if !has_component_data(world,entity,"Terrain") || !terrain_valid(value) {return false}
	commit_component_value(world,entity,"Terrain",&world.terrains,value)
	return true
}

// Borrowed read-only data, valid until the next sync_terrains or World destruction.
terrain_runtime :: proc(world: ^World, entity: Entity) -> (terrain.Data,u64,bool) {
	state,found := world.terrain_states[entity]
	return state.data,state.revision,found
}

// Run before simulation and drawing. The scene-owning engine does this even
// while paused. Callback loops should call this explicitly after asset polling.
sync_terrains :: proc(world: ^World, manager: ^assets.Asset_Manager) {
	for entity,value in world.terrains {
		data,revision,ok := assets.terrain_data(manager,value.asset)
		if !ok {continue}
		old,found := world.terrain_states[entity]
		if found && old.source == value.asset && old.asset_revision == revision {continue}
		// Build a single collision mesh to identify shared edges across rendering
		// chunks. Its topology is exactly the same as the rendered grid.
		mesh := terrain_collision_mesh(data)
		if mesh == nil {
			assets.report_failure(manager,{kind=.Terrain,operation=.Load,source_path=value.asset,field="collision",asset_path=value.asset,detail="could not build terrain collision; keeping previous terrain"})
			continue
		}
		assets.resolve_asset_failure(manager,value.asset,"collision",value.asset)
		state := Terrain_Runtime{data=terrain.clone(data),mesh=mesh,asset_revision=revision}
		state.source,_ = strings.clone(value.asset)
		world.terrain_revision += 1
		state.revision = world.terrain_revision
		remove_terrain_runtime(world,entity)
		world.terrain_states[entity] = state
		world.physics_3d.needs_sync = true
	}
}

terrain_collision_mesh :: proc(data: terrain.Data) -> ^b3.MeshData {
	w,h := data.description.resolution[0],data.description.resolution[1]
	vertices := make([]b3.Vec3,w*h)
	defer delete(vertices)
	indices := make([]i32,(w-1)*(h-1)*6)
	defer delete(indices)
	for z in 0..<h {for x in 0..<w {p := terrain.position(data,x,z); vertices[z*w+x] = {p[0],p[1],p[2]}}}
	i := 0
	for z in 0..<h-1 {for x in 0..<w-1 {for index in terrain.cell_indices(x,z,w) {indices[i] = i32(index); i += 1}}}
	def := b3.MeshDef{vertices=raw_data(vertices),indices=raw_data(indices),vertexCount=i32(len(vertices)),triangleCount=i32(len(indices)/3),identifyEdges=true,useMedianSplit=true}
	return b3.CreateMesh(def,nil,0)
}

remove_terrain_runtime :: proc(world: ^World, entity: Entity) {
	state,found := world.terrain_states[entity]
	if !found {return}
	release_terrain_runtime(world,entity,&state)
	delete_key(&world.terrain_states,entity)
}

release_terrain_runtime :: proc(world: ^World, entity: Entity, state: ^Terrain_Runtime) {
	physics_3d_remove_entity(world,entity)
	if state.mesh != nil {b3.DestroyMesh(state.mesh)}
	terrain.destroy(&state.data)
	delete(state.source)
	state^ = {}
}

destroy_terrains :: proc(world: ^World) {
	for entity,&state in world.terrain_states {release_terrain_runtime(world,entity,&state)}
	delete(world.terrain_states)
	delete(world.terrains)
	world.terrain_states = nil
	world.terrains = nil
}

// Match Rune's renderer hierarchy: additive positions/Euler angles and
// multiplicative scales. Terrain uses positive scale on every axis.
terrain_transform :: proc(world: ^World, entity: Entity) -> (Transform,bool) {
	result := Transform{scale={1,1,1}}
	if _,found := world.transforms[entity]; !found {return {},false}
	current := entity
	for current != 0 {
		if t,found := world.transforms[current]; found {
			result.position += t.position
			result.rotation += t.rotation
			result.scale *= t.scale
		}
		current = world.parents[current]
	}
	for n in result.scale {if !(n > 0) {return {},false}}
	return result,component_value_valid(result)
}

sync_terrain_bodies :: proc(world: ^World) {
	for entity,&state in world.terrain_states {
		value,has_terrain := world.terrains[entity]
		t,valid := terrain_transform(world,entity)
		if !has_terrain || !value.collision || !is_enabled(world,entity) || !valid {
			if _,found := world.box3d_bodies[entity]; found {physics_3d_remove_entity(world,entity)}
			continue
		}
		layers,_ := entity_layer_mask(world,entity)
		if _,exists := world.box3d_bodies[entity]; exists {
			if state.body_transform == t && state.body_layers == layers {continue}
			physics_3d_remove_entity(world,entity)
		}
		native := create_box3d_body_id(world,{body_type="static"},t)
		def := create_box3d_shape_def(world,entity,value.friction,0,0)
		shape := b3.CreateMeshShape(native,def,state.mesh,{t.scale[0],t.scale[1],t.scale[2]})
		world.physics_3d.shapes[b3.StoreShapeId(shape)] = {entity,"Terrain"}
		world.box3d_bodies[entity] = native
		state.body_transform = t
		state.body_layers = layers
	}
}
