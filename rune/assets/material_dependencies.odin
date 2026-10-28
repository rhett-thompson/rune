package assets

import rl "vendor:raylib"

Material_Dependency_State :: struct {
	signature, fingerprint, revision: u64,
	paths: [9]string,
}

Generated_ORM_State :: struct {
	paths: [3]string,
	references: int,
	retired, anonymous_borrow: bool,
	borrowed_materials: [dynamic]string,
}

material_dependency_paths :: proc(data: Material_Data) -> [9]string {
	return {data.surface_shader,data.texture,data.normal,data.emission,data.orm_texture,
		data.roughness_texture,data.metallic_texture,data.ao_texture,data.height_texture}
}

watch_material_source :: proc(manager: ^Asset_Manager, path: string) {
	if manager == nil || path == "" {return}
	if manager.material_texture_watches == nil {manager.material_texture_watches=make(map[string]i64)}
	if manager.material_file_versions == nil {manager.material_file_versions=make(map[string]u64)}
	if _,found:=manager.material_texture_watches[path]; !found {
		owned:=retain_path(manager,path)
		manager.material_texture_watches[owned]=modified_time(resolve_path(manager,path))
	}
	if manager.material_file_versions[path]==0 {manager.material_file_versions[retain_path(manager,path)]=1}
}

material_file_version :: proc(manager: ^Asset_Manager, path: string) -> u64 {
	if manager==nil || path=="" {return 0}
	return manager.material_file_versions[path]
}

material_fingerprint_from_sources :: proc(manager: ^Asset_Manager, signature: u64, paths: [9]string) -> u64 {
	result:=signature
	for path in paths {result=hash_value(result,material_file_version(manager,path))}
	return result
}

// Fingerprints include the complete variant plus watched source generations.
// Existing watches are metadata lookups; only registering a new path stats it.
material_dependency_fingerprint :: proc(manager: ^Asset_Manager, path: string, data: Material_Data) -> u64 {
	watch_material_textures(manager,data)
	return material_fingerprint_from_sources(manager,material_data_signature(data),material_dependency_paths(data))
}

// O(1) authored-material fast path. Initial loading/preview creation registers
// the state; successful reloads and source edits update only affected paths.
material_path_revision :: proc(manager: ^Asset_Manager, path: string) -> u64 {
	if manager==nil {return 0}
	return manager.material_dependencies[path].revision
}

update_material_path_dependencies :: proc(manager: ^Asset_Manager, path: string, data: Material_Data) {
	if manager==nil || path=="" {return}
	watch_material_textures(manager,data)
	if manager.material_dependencies==nil {manager.material_dependencies=make(map[string]Material_Dependency_State)}
	state:=manager.material_dependencies[path]
	signature:=material_data_signature(data)
	paths:=material_dependency_paths(data)
	fingerprint:=material_fingerprint_from_sources(manager,signature,paths)
	if state.revision!=0 && state.fingerprint==fingerprint {return}
	for &source in paths {source=retain_path(manager,source)}
	state.signature,state.fingerprint,state.paths=signature,fingerprint,paths
	state.revision+=1; if state.revision==0 {state.revision=1}
	manager.material_dependencies[retain_path(manager,path)]=state
}

refresh_visible_material_dependencies :: proc(manager: ^Asset_Manager, path: string) {
	if preview,found:=manager.material_previews[path]; found {update_material_path_dependencies(manager,path,preview);return}
	if authored,found:=manager.materials[path]; found {update_material_path_dependencies(manager,path,authored.data);return}
	if state,found:=manager.material_dependencies[path]; found {
		state.revision+=1; if state.revision==0 {state.revision=1}
		state.signature,state.fingerprint,state.paths=0,0,{}
		manager.material_dependencies[path]=state
	}
}

bump_material_revision :: proc(manager: ^Asset_Manager) {
	manager.material_revision+=1
	if manager.material_revision==0 {manager.material_revision=1}
}

// Returns whether an existing watch changed. No diagnostics/cache mutation
// happens on workers; both polling and completed texture installs call here.
material_dependency_source_changed :: proc(manager: ^Asset_Manager, path: string, stamp: i64, force: bool=false) -> bool {
	previous,watched:=manager.material_texture_watches[path]
	if !watched || (!force && previous==stamp) {return false}
	manager.material_texture_watches[path]=stamp
	version:=manager.material_file_versions[path]+1; if version==0 {version=1}
	if manager.material_file_versions==nil {manager.material_file_versions=make(map[string]u64)}
	manager.material_file_versions[retain_path(manager,path)]=version
	for material,entry in manager.material_dependencies {
		state:=entry
		for source in state.paths {
			if source!=path {continue}
			state.fingerprint=material_fingerprint_from_sources(manager,state.signature,state.paths)
			state.revision+=1; if state.revision==0 {state.revision=1}
			manager.material_dependencies[material]=state
			break
		}
	}
	retire_generated_orm_source(manager,path)
	return true
}

material_texture_committed :: proc(manager: ^Asset_Manager, path: string, stamp: i64) {
	// Polling may have observed this stamp before an asynchronous GPU install.
	// The install still changes borrowed texture handles and must invalidate
	// dependent caches even when the file timestamp has already been consumed.
	if manager!=nil && material_dependency_source_changed(manager,path,stamp,true) {bump_material_revision(manager)}
}

register_generated_orm :: proc(manager: ^Asset_Manager, key: u64, data: Material_Data) {
	if manager.generated_orm_states==nil {manager.generated_orm_states=make(map[u64]Generated_ORM_State)}
	manager.generated_orm_states[key]={paths={retain_path(manager,data.ao_texture),retain_path(manager,data.roughness_texture),retain_path(manager,data.metallic_texture)}}
}

destroy_generated_orm_entry :: proc(manager: ^Asset_Manager, key: u64) {
	if asset,found:=manager.generated_orm_textures[key]; found {
		if rl.IsTextureValid(asset.texture) {rl.UnloadTexture(asset.texture)}
		delete_key(&manager.generated_orm_textures,key)
	}
	if state,found:=manager.generated_orm_states[key]; found {delete(state.borrowed_materials);delete_key(&manager.generated_orm_states,key)}
}

retire_generated_orm_entry :: proc(manager: ^Asset_Manager, key: u64) {
	state:=manager.generated_orm_states[key]
	if state.references==0 {destroy_generated_orm_entry(manager,key);return}
	state.retired=true
	manager.generated_orm_states[key]=state
}

retire_generated_orm_source :: proc(manager: ^Asset_Manager, path: string) {
	keys:=make([dynamic]u64);defer delete(keys)
	for key,state in manager.generated_orm_states {for source in state.paths {if source==path {append(&keys,key);break}}}
	for key in keys {retire_generated_orm_entry(manager,key)}
}

// Metadata/preview changes remove only legacy borrows belonging to that
// material. Bridge leases remain valid until their replacement is installed.
retire_generated_orm_material :: proc(manager: ^Asset_Manager, path: string) {
	keys:=make([dynamic]u64);defer delete(keys)
	for key,entry in manager.generated_orm_states {
		state:=entry
		removed:=false
		for index:=len(state.borrowed_materials)-1;index>=0;index-=1 {
			if state.borrowed_materials[index]==path {ordered_remove(&state.borrowed_materials,index);removed=true}
		}
		if !removed {continue}
		manager.generated_orm_states[key]=state
		if !state.anonymous_borrow && len(state.borrowed_materials)==0 && state.references==0 {append(&keys,key)}
	}
	for key in keys {retire_generated_orm_entry(manager,key)}
}

// Borrowed textures expire on an affected source refresh or explicit clear.
record_generated_orm_borrow :: proc(manager: ^Asset_Manager, key: u64, material: string) {
	state:=manager.generated_orm_states[key]
	if material=="" {state.anonymous_borrow=true}
	else {
		found:=false;for path in state.borrowed_materials {if path==material {found=true;break}}
		if !found {append(&state.borrowed_materials,retain_path(manager,material))}
	}
	manager.generated_orm_states[key]=state
}

// The returned lease survives refresh until released. The owning renderer must
// release leases before manager shutdown; the manager still owns GPU deletion.
lease_material_orm_texture :: proc(manager: ^Asset_Manager, data: Material_Data, material_path: string="") -> (rl.Texture2D,u64,bool) {
	texture,key,ok:=ensure_generated_orm_texture(manager,data,material_path)
	if !ok {return {},0,false}
	state:=manager.generated_orm_states[key];state.references+=1;manager.generated_orm_states[key]=state
	return texture,key,true
}

release_material_orm_texture :: proc(manager: ^Asset_Manager, key: u64) {
	if manager==nil {return}
	state,found:=manager.generated_orm_states[key]
	if !found {return}
	assert(state.references>0,"unbalanced generated ORM lease release")
	state.references-=1;manager.generated_orm_states[key]=state
	if state.references==0 && (state.retired || (!state.anonymous_borrow && len(state.borrowed_materials)==0)) {destroy_generated_orm_entry(manager,key)}
}

// Shutdown ends all borrowing contracts. Engine/renderer ownership order joins
// work and releases material leases before reaching this final GPU cleanup.
shutdown_material_dependencies :: proc(manager: ^Asset_Manager) {
	for _,state in manager.generated_orm_states {delete(state.borrowed_materials)}
	for _,asset in manager.generated_orm_textures {if rl.IsTextureValid(asset.texture) {rl.UnloadTexture(asset.texture)}}
	clear(&manager.generated_orm_textures)
	delete(manager.generated_orm_states);manager.generated_orm_states=nil
	delete(manager.material_dependencies);manager.material_dependencies=nil
	delete(manager.material_file_versions);manager.material_file_versions=nil
}
