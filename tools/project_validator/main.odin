package main

import "core:fmt"
import "core:os"
import "rune:validation"

main :: proc() {
	project_path := "examples/hello_world/project.json"
	if len(os.args) > 1 { project_path = string(os.args[1]) }
	report := validation.validate_project(project_path)
	if validation.is_valid(&report) {
		fmt.println("Project validation passed:", project_path)
		return
	}
	for diagnostic in report.diagnostics {
		fmt.println(diagnostic.file, ": ", diagnostic.path, ": ", diagnostic.message)
	}
	os.exit(1)
}
