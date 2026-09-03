package main

import "core:fmt"
import "core:strings"
import "rune:assets"
import "rune:validation"

main :: proc() {
	report := validation.validate_project("tools/asset_validation/fixtures/project.json")
	defer validation.destroy_report(&report)
	assert(!validation.is_valid(&report))
	assert(
		has_diagnostic(
			&report,
			"$.entities[0].components.SpriteRenderer.texture",
			"unsupported texture format .jpg",
		),
	)
	assert(has_diagnostic(&report, "$.albedo", "unsupported texture format .jpg"))
	assert(has_diagnostic(&report, "$.normal", "unsupported texture format .jpeg"))
	assert(
		has_diagnostic(
			&report,
			"$.entities[2].components.ModelRenderer.materials.bad",
			"material slot must be an integer",
		),
	)
	validate_runtime_diagnostics()
	validate_asset_cache_ownership()
	validate_repeated_report_ownership()
	fmt.println("Asset reference validation passed")
}

validate_repeated_report_ownership :: proc() {
	for _ in 0 ..< 16 {
		report := validation.validate_project("examples/hello_world/project.json")
		assert(validation.is_valid(&report))
		validation.destroy_report(&report)
		validation.destroy_report(&report)
	}
}

validate_runtime_diagnostics :: proc() {
	log := assets.init_diagnostic_log()
	defer assets.destroy_diagnostic_log(&log)
	diagnostic := assets.Diagnostic {
		kind        = .Texture,
		operation   = .Reload,
		source_path = "assets/materials/test.material.json",
		field       = "$.normal",
		asset_path  = "assets/textures/missing.png",
		detail      = "replacement is invalid; keeping the previous texture",
	}
	assert(assets.record_failure(&log, diagnostic))
	assert(!assets.record_failure(&log, diagnostic))
	assert(len(log.pending) == 1)
	message := assets.format_diagnostic(log.pending[0])
	assert(strings.contains(message, diagnostic.source_path))
	assert(strings.contains(message, diagnostic.field))
	assert(strings.contains(message, diagnostic.asset_path))
	delete(message)
	assets.resolve_failure(&log, diagnostic.source_path, diagnostic.field, diagnostic.asset_path)
	assert(assets.record_failure(&log, diagnostic))
}

validate_asset_cache_ownership :: proc() {
	manager := assets.Asset_Manager {
		retained_paths = make(map[string]string),
	}
	root_source, _ := strings.clone("examples/hello_world")
	manager.root = assets.retain_path(&manager, root_source)
	resolved := assets.resolve_path(&manager, "assets/fonts/mecha.png")
	root_bytes := transmute([]u8)root_source
	root_bytes[0] = 'X'
	assert(manager.root == "examples/hello_world")
	assert(assets.resolve_path(&manager, "assets/fonts/mecha.png") == resolved)
	source, _ := strings.clone("assets/textures/test.png")
	retained := assets.retain_path(&manager, source)
	bytes := transmute([]u8)source
	bytes[0] = 'X'
	assert(retained == "assets/textures/test.png")
	assert(assets.retain_path(&manager, retained) == retained)
	assert(len(manager.retained_paths) == 3)
	delete(root_source)
	delete(source)
	assets.destroy_retained_paths(&manager)
	assets.destroy_retained_paths(&manager)

	borrowed := assets.Material_Data {
		texture      = "assets/textures/test.png",
		filter       = "point",
		transparency = "disabled",
		blend        = "mix",
		cull         = "back",
	}
	owned := assets.clone_material_data(borrowed)
	assert(owned.texture == borrowed.texture)
	assert(owned.filter == borrowed.filter)
	assets.destroy_material_data(&owned)
}

has_diagnostic :: proc(report: ^validation.Report, path, message: string) -> bool {
	for diagnostic in report.diagnostics {
		if diagnostic.path == path && strings.contains(diagnostic.message, message) {return true}
	}
	return false
}
