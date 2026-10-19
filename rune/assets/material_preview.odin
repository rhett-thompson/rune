package assets

// Override one material path in memory for live authoring. The supplied data
// should start from material_data/authored_material_data and obey Material_Data's
// normal authoring limits. The manager clones all strings before replacing any
// previous preview, so passing a borrowed current preview is safe.
// This does not modify a file. Every renderer using this asset manager and path
// observes the preview, including existing material slots and instanced meshes.
set_material_preview :: proc(manager: ^Asset_Manager, path: string, data: Material_Data) -> bool {
	if manager == nil || len(path) == 0 {return false}
	if previous, found := manager.material_previews[path]; found {
		if material_data_signature(previous) == material_data_signature(data) {return true}
	}
	owned := clone_material_data(data)
	if manager.material_previews == nil {manager.material_previews = make(map[string]Material_Data)}
	owned_path := retain_path(manager, path)
	if previous, found := manager.material_previews[path]; found {
		destroy_material_data(&previous)
	}
	manager.material_previews[owned_path] = owned
	watch_material_textures(manager, owned)
	material_preview_changed(manager)
	return true
}

has_material_preview :: proc(manager: ^Asset_Manager, path: string) -> bool {
	if manager == nil {return false}
	_, found := manager.material_previews[path]
	return found
}

// Restore the current authored file definition. After saving a preview to disk,
// call refresh_materials first so clearing it cannot briefly show the old file.
clear_material_preview :: proc(manager: ^Asset_Manager, path: string) -> bool {
	if manager == nil {return false}
	preview, found := manager.material_previews[path]
	if !found {return false}
	delete_key(&manager.material_previews, path)
	destroy_material_data(&preview)
	material_preview_changed(manager)
	return true
}

clear_material_previews :: proc(manager: ^Asset_Manager) {
	if manager == nil || len(manager.material_previews) == 0 {return}
	for _, preview in manager.material_previews {
		data := preview
		destroy_material_data(&data)
	}
	clear(&manager.material_previews)
	material_preview_changed(manager)
}

@(private)
material_preview_changed :: proc(manager: ^Asset_Manager) {
	clear_generated_orm_textures(manager)
	manager.material_revision += 1
	if manager.material_revision == 0 {manager.material_revision = 1}
}
