package validation

import "core:encoding/json"
import "core:fmt"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

SUPPORTED_TEXTURE_FORMATS :: ".png, .bmp, .gif, .qoi, and .dds"

supported_texture_path :: proc(path: string) -> bool {
	extension := strings.to_lower(filepath.ext(path), context.temp_allocator)
	return(
		extension == ".png" ||
		extension == ".bmp" ||
		extension == ".gif" ||
		extension == ".qoi" ||
		extension == ".dds" \
	)
}

validate_texture_reference :: proc(report: ^Report, file, path, asset, project_directory: string) {
	if !supported_texture_path(asset) {
		extension := filepath.ext(asset)
		if len(extension) == 0 {extension = "<none>"}
		add(
			report,
			file,
			path,
			fmt.tprintf(
				"unsupported texture format %s; supported formats are %s",
				extension,
				SUPPORTED_TEXTURE_FORMATS,
			),
		)
	}
	if len(project_directory) > 0 && !file_exists(path_from(report, project_directory, asset)) {
		add(report, file, path, fmt.tprint("referenced asset does not exist: ", asset))
	}
}

validate_material_reference :: proc(
	report: ^Report,
	file, path: string,
	value: json.Value,
	project_directory: string,
) {
	material, ok := value.(json.String)
	if !ok || len(material) == 0 {
		add(report, file, path, "must be a non-empty material path")
		return
	}
	if len(project_directory) == 0 {return}
	resolved := path_from(report, project_directory, material)
	if !file_exists(resolved) {
		add(report, file, path, fmt.tprint("referenced material does not exist: ", material))
		return
	}
	validate_material(report, resolved, project_directory)
}

validate_material_overrides :: proc(
	report: ^Report,
	file, path: string,
	component: json.Object,
	project_directory: string,
) {
	value, found := component["materials"]
	if !found {return}
	overrides, ok := value.(json.Object)
	if !ok {
		add(
			report,
			file,
			field_path(path, "materials"),
			"must be an object keyed by material slot",
		)
		return
	}
	for slot_name, material_value in overrides {
		slot_path := field_path(field_path(path, "materials"), slot_name)
		slot, slot_ok := strconv.parse_int(slot_name, 10)
		if !slot_ok || slot < 0 || slot > 2147483647 {
			add(
				report,
				file,
				slot_path,
				"material slot must be an integer from 0 through 2147483647",
			)
			continue
		}
		validate_material_reference(report, file, slot_path, material_value, project_directory)
	}
}
