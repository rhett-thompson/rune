package validation

import "core:path/filepath"

// Validate another scene with the project's layer table and asset root. This
// supports package inspection of code-loaded scenes without rewriting JSON.
validate_project_scene :: proc(project_path, scene_path: string) -> Report {
	report := init_report()
	project, ok := read_json_object(project_path, &report)
	if !ok {return report}
	root, _ := filepath.split(project_path)
	layers := validate_layers(&report, project_path, project)
	validate_scene_at(&report, scene_path, layers, root)
	return report
}
