package validation

import "core:encoding/json"
import "core:math"

// Keep these startup settings consistent with schemas/project.schema.json.
// Use f64 so a fractional value cannot become integral through f32 rounding.
project_integer_in_range :: proc(value: json.Value, minimum, maximum: int) -> bool {
	#partial switch number in value {
	case json.Integer:
		return number >= json.Integer(minimum) && number <= json.Integer(maximum)
	case json.Float:
		n := f64(number)
		return n >= f64(minimum) && n <= f64(maximum) && math.floor(n) == n
	}
	return false
}

project_setting_keys :: proc(report: ^Report, file, path: string, settings: json.Object, allowed: []string) {
	for field in settings {
		known := false
		for name in allowed {if name == field {known = true; break}}
		if !known {add(report, file, field_path(path, field), "unknown setting")}
	}
}

validate_project_runtime_settings :: proc(report: ^Report, file: string, project: json.Object) {
	jobs, jobs_ok := object_field(report, file, "$", project, "jobs", false)
	if jobs_ok {
		project_setting_keys(report, file, "$.jobs", jobs, {"worker_count", "queue_capacity"})
		if value, found := jobs["worker_count"]; found && !project_integer_in_range(value, 0, 32) {
			add(report, file, "$.jobs.worker_count", "must be an integer from 0 through 32")
		}
		if value, found := jobs["queue_capacity"]; found && !project_integer_in_range(value, 1, 4096) {
			add(report, file, "$.jobs.queue_capacity", "must be an integer from 1 through 4096")
		}
	}
	physics, physics_ok := object_field(report, file, "$", project, "physics_3d", false)
	if physics_ok {
		project_setting_keys(report, file, "$.physics_3d", physics, {"worker_count"})
		if value, found := physics["worker_count"]; found && !project_integer_in_range(value, 1, 32) {
			add(report, file, "$.physics_3d.worker_count", "must be an integer from 1 through 32")
		}
	}

	render, render_ok := object_field(report, file, "$", project, "render_3d", false)
	if !render_ok {return}
	project_setting_keys(report, file, "$.render_3d", render, {"shadows"})
	shadows, shadows_ok := object_field(report, file, "$.render_3d", render, "shadows", false)
	if !shadows_ok {return}
	fields := []string{"directional_resolution", "spot_resolution", "omni_resolution"}
	project_setting_keys(report, file, "$.render_3d.shadows", shadows, fields)
	for field in fields {
		if value, found := shadows[field]; found && !project_integer_in_range(value, 2, 8192) {
			add(report, file, field_path("$.render_3d.shadows", field), "must be an integer from 2 through 8192")
		}
	}
}
