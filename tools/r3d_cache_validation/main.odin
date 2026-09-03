package main

import "core:fmt"
import "core:strings"
import "rune:assets"
import bridge "rune:r3d_bridge"

main :: proc() {
	validate_signature_ownership()
	validate_path_ownership()
	fmt.println("r3d cache ownership validation passed")
}

validate_signature_ownership :: proc() {
	data := assets.Material_Data {
		base_color = {255, 128, 64, 255},
		texture    = "assets/textures/albedo.png",
		normal     = "assets/textures/normal.png",
		filter     = "anisotropic_8x",
		mipmaps    = true,
	}
	first := bridge.material_signature(data)
	second := bridge.material_signature(data)
	assert(first == second)
	data.normal_scale = 2
	assert(bridge.material_signature(data) != first)
}

validate_path_ownership :: proc() {
	ctx := bridge.Context {
		retained_paths = make(map[string]string),
	}
	source, _ := strings.clone("assets/materials/crate.material.json")
	retained := bridge.retain_path(&ctx, source)
	bytes := transmute([]u8)source
	bytes[0] = 'X'
	assert(retained == "assets/materials/crate.material.json")
	assert(bridge.retain_path(&ctx, retained) == retained)
	assert(len(ctx.retained_paths) == 1)
	delete(source)
	bridge.destroy_retained_paths(&ctx)
}
