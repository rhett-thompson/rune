package main

import "core:fmt"
import "core:strings"
import "rune:assets"
import "rune:validation"

main :: proc() {
	report := validation.validate_project("tools/asset_validation/fixtures/project.json")
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
	fmt.println("Asset reference validation passed")
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

has_diagnostic :: proc(report: ^validation.Report, path, message: string) -> bool {
	for diagnostic in report.diagnostics {
		if diagnostic.path == path && strings.contains(diagnostic.message, message) {return true}
	}
	return false
}
