package main

import "core:fmt"
import "core:strings"
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
	fmt.println("Asset reference validation passed")
}

has_diagnostic :: proc(report: ^validation.Report, path, message: string) -> bool {
	for diagnostic in report.diagnostics {
		if diagnostic.path == path && strings.contains(diagnostic.message, message) {return true}
	}
	return false
}
