package assets

import "core:strings"
import "core:testing"

@(private)
material_preview_test_manager :: proc() -> Asset_Manager {
	return {
		materials = make(map[string]Material_Asset),
		material_texture_watches = make(map[string]i64),
		retained_paths = make(map[string]string),
		diagnostics = init_diagnostic_log(),
		material_revision = 1,
	}
}

@(test)
material_preview_preserves_authored_data_and_owns_strings :: proc(t: ^testing.T) {
	manager := material_preview_test_manager()
	defer shutdown(&manager)
	path := "materials/test.json"
	authored := Material_Data{
		base_color = {32, 64, 96, 255}, roughness = 0.8,
		texture = "textures/albedo.png", normal = "textures/normal.png",
		surface_shader = "shaders/test.glsl", surface_shader_time = true,
		procedural = default_procedural_material(),
	}
	manager.materials[retain_path(&manager, path)] = {data = clone_material_data(authored)}
	preview := clone_material_data(authored)
	preview.roughness = 0.2
	testing.expect(t, set_material_preview(&manager, path, preview))
	destroy_material_data(&preview)
	visible, loaded := material_data(&manager, path)
	testing.expect(t, loaded && visible.roughness == 0.2 && visible.texture == authored.texture)
	testing.expect(t, visible.normal == authored.normal && visible.surface_shader == authored.surface_shader)
	testing.expect(t, visible.surface_shader_time && visible.procedural == authored.procedural)
	disk, disk_loaded := authored_material_data(&manager, path)
	testing.expect(t, disk_loaded && disk.roughness == 0.8, "preview leaves cached authored data intact")
	testing.expect(t, manager.material_revision == 2 && has_material_preview(&manager, path))
	// Replacing a preview with a borrowed value must clone before freeing it.
	visible.metallic = 0.7
	testing.expect(t, set_material_preview(&manager, path, visible))
	updated, _ := material_data(&manager, path)
	testing.expect(t, updated.metallic == 0.7 && updated.texture == authored.texture)
	testing.expect(t, clear_material_preview(&manager, path))
	restored, _ := material_data(&manager, path)
	testing.expect(t, restored.roughness == authored.roughness && !has_material_preview(&manager, path))
	testing.expect(t, !clear_material_preview(&manager, path))
}

@(test)
material_preview_revision_changes_only_when_visible_data_changes :: proc(t: ^testing.T) {
	manager := material_preview_test_manager()
	defer shutdown(&manager)
	data := Material_Data{base_color = {255, 255, 255, 255}, roughness = 0.5}
	testing.expect(t, !set_material_preview(nil, "materials/a.json", data))
	testing.expect(t, !set_material_preview(&manager, "", data) && manager.material_revision == 1)
	testing.expect(t, set_material_preview(&manager, "materials/a.json", data))
	revision := material_asset_revision(&manager)
	testing.expect(t, set_material_preview(&manager, "materials/a.json", data))
	testing.expect(t, material_asset_revision(&manager) == revision, "unchanged previews do not invalidate GPU caches")
	testing.expect(t, set_material_preview(&manager, "materials/b.json", data))
	clear_material_previews(&manager)
	testing.expect(t, !has_material_preview(&manager, "materials/a.json") && !has_material_preview(&manager, "materials/b.json"))
	testing.expect(t, material_asset_revision(&manager) == revision + 2)
	clear_material_previews(&manager)
	testing.expect(t, material_asset_revision(&manager) == revision + 2, "clearing empty previews is a no-op")
}

@(test)
material_preview_retains_path_and_allows_authored_updates :: proc(t: ^testing.T) {
	manager := material_preview_test_manager()
	defer shutdown(&manager)
	path, _ := strings.clone("materials/preview.json")
	data := Material_Data{roughness = 0.25}
	testing.expect(t, set_material_preview(&manager, path, data))
	delete(path)
	key := "materials/preview.json"
	// File hot reload replaces this separate cache while a preview is active.
	manager.materials[retain_path(&manager, key)] = {data = clone_material_data(Material_Data{roughness = 0.9})}
	visible, ok := material_data(&manager, key)
	testing.expect(t, ok && visible.roughness == 0.25)
	testing.expect(t, clear_material_preview(&manager, key))
	restored, restored_ok := material_data(&manager, key)
	testing.expect(t, restored_ok && restored.roughness == 0.9, "clear uses the latest authored data")
}
