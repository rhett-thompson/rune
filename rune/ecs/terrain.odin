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
	asset_revision, source_revision, revision, detail_revision: u64,
	chunk_revisions: []u64,
	committed_heights: []f32,
	dirty_samples: terrain.Sample_Rect,
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

// Borrowed read-only preview data. Reacquire after edits, terrain sync or removal.
terrain_runtime :: proc(world: ^World, entity: Entity) -> (terrain.Data,u64,bool) {
	state,found := world.terrain_states[entity]
	return state.data,state.revision,found
}

// Bridge cache generations. Each chunk retains its last changed revision so
// independent render contexts can catch up after skipping any number of draws.
terrain_render_updates :: proc(world: ^World, entity: Entity) -> (source_revision: u64, chunk_revisions: []u64, detail_revision: u64) {
	state := world.terrain_states[entity]
	return state.source_revision, state.chunk_revisions, state.detail_revision
}

// Same borrowing rules as terrain_runtime. Detail and layer queries use
// committed heights when the terrain has details or material layers.
terrain_committed_data :: proc(world: ^World, entity: Entity) -> terrain.Data {
	state := world.terrain_states[entity]
	data := state.data
	if state.committed_heights != nil {data.heights = state.committed_heights}
	return data
}

// Bounding rectangle of samples changed since the last successful commit.
terrain_dirty_region :: proc(world: ^World, entity: Entity) -> (terrain.Sample_Rect, bool) {
	if world == nil {return {}, false}
	rect := world.terrain_states[entity].dirty_samples
	return rect, rect.x0 < rect.x1
}

// Patch previews on the World owner before drawing. Heights are absolute local
// elevations, laid out by X then Z over the half-open sample rectangle.
update_terrain_region :: proc(world: ^World, entity: Entity, x0,z0,x1,z1: int, heights: []f32) -> bool {
	if world == nil {return false}
	state, found := world.terrain_states[entity]
	if !found {return false}
	d := state.data.description
	w,h := d.resolution[0],d.resolution[1]
	if x0 < 0 || z0 < 0 || x1 > w || z1 > h || x0 >= x1 || z0 >= z1 {return false}
	width := x1-x0
	if len(heights) != width*(z1-z0) {return false}
	// Match the range available through valid heightmap descriptors. The
	// comparisons also reject infinities and NaNs before touching any sample.
	for value in heights {if !(value >= -100000 && value <= 200000) {return false}}

	// A caller can use a slice of the borrowed surface as the patch input.
	// Snapshot it if it shares the destination storage.
	patch := heights
	start := uintptr(raw_data(state.data.heights))
	input := uintptr(raw_data(heights))
	if input >= start && input-start < uintptr(len(state.data.heights))*size_of(f32) {
		patch = make([]f32, len(heights))
		copy(patch, heights)
	}
	defer if raw_data(patch) != raw_data(heights) {delete(patch)}

	columns, rows := terrain.chunk_grid(d)
	revision := world.terrain_revision+1
	changed := false
	for z in z0..<z1 {
		for x in x0..<x1 {
			value := patch[(z-z0)*width+x-x0]
			if state.data.heights[z*w+x] == value {continue}
			state.data.heights[z*w+x] = value
			if state.dirty_samples.x0 == state.dirty_samples.x1 {
				state.dirty_samples = {x,z,x+1,z+1}
			} else {
				rect := &state.dirty_samples
				rect.x0,rect.z0 = min(rect.x0,x),min(rect.z0,z)
				rect.x1,rect.z1 = max(rect.x1,x+1),max(rect.z1,z+1)
			}
			// Vertices at the sample and its axial neighbors use this height.
			// A chunk contains both of its boundary rows and columns.
			mark_terrain_chunks(state.chunk_revisions,columns,rows,d.chunk_cells,max(0,x-1),z,min(w-1,x+1),z,revision)
			mark_terrain_chunks(state.chunk_revisions,columns,rows,d.chunk_cells,x,max(0,z-1),x,min(h-1,z+1),revision)
			changed = true
		}
	}
	if changed {
		world.terrain_revision = revision
		state.revision = revision
		world.terrain_states[entity] = state
	}
	return true
}

@(private)
mark_terrain_chunks :: proc(revisions: []u64, columns,rows,cell_size,x0,z0,x1,z1: int, revision: u64) {
	for row in max(0,z0-1)/cell_size..=min(rows-1,z1/cell_size) {
		for column in max(0,x0-1)/cell_size..=min(columns-1,x1/cell_size) {
			revisions[row*columns+column] = revision
		}
	}
}

// Publish the preview to collision and detail scatter. The existing body stays
// available until its replacement mesh has been built successfully.
commit_terrain_region :: proc(world: ^World, entity: Entity) -> bool {
	if world == nil {return false}
	state, found := world.terrain_states[entity]
	if !found {return false}
	rect := state.dirty_samples
	if rect.x0 == rect.x1 {return true}
	width := state.data.description.resolution[0]
	height_limit := b3.HUGE()
	// The authored height range can exceed the native mesh bounds. Only
	// pending samples can extend the bounds of the last successfully built mesh.
	for z in rect.z0..<rect.z1 {
		for height in state.data.heights[z*width+rect.x0:z*width+rect.x1] {
			if abs(height) > height_limit {return false}
		}
	}
	mesh := terrain_collision_mesh(state.data)
	if mesh == nil {return false}
	physics_3d_remove_entity(world,entity)
	b3.DestroyMesh(state.mesh)
	state.mesh = mesh
	if state.committed_heights != nil {
		for z in rect.z0..<rect.z1 {
			start,end := z*width+rect.x0,z*width+rect.x1
			copy(state.committed_heights[start:end],state.data.heights[start:end])
		}
	}
	state.detail_revision = state.revision
	state.dirty_samples = {}
	world.terrain_states[entity] = state
	return true
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
		columns,rows := terrain.chunk_grid(data.description)
		state.chunk_revisions = make([]u64, columns*rows)
		if len(data.description.details) > 0 || len(data.description.layers) > 0 {
			state.committed_heights = make([]f32, len(data.heights))
			copy(state.committed_heights, data.heights)
		}
		state.source,_ = strings.clone(value.asset)
		world.terrain_revision += 1
		state.revision = world.terrain_revision
		state.source_revision = state.revision
		state.detail_revision = state.revision
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
	delete(state.chunk_revisions)
	delete(state.committed_heights)
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

// Match Rune's 3D renderer hierarchy. Terrain uses positive scale on every axis.
terrain_transform :: proc(world: ^World, entity: Entity) -> (Transform,bool) {
	if _,found := world.transforms[entity]; !found {return {},false}
	result := world_transform_3d(world, entity)
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
