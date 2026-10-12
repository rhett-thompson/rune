package r3d_bridge

import "core:strings"
import "rune:assets"
import r3d "r3d:r3d"

load_material_surface_shader :: proc(ctx: ^Context, manager: ^assets.Asset_Manager, path: string, data: assets.Material_Data, reload: bool) -> (^r3d.SurfaceShader, bool) {
	if data.surface_shader == "" {return nil, true}
	// Without a cache key the bridge cannot own/release an authored shader.
	if path == "" {return nil, false}
	full_path := resolve_path(ctx, data.surface_shader)
	shader := r3d.LoadSurfaceShader(strings.clone_to_cstring(full_path, context.temp_allocator))
	if manager != nil {
		if shader != nil {
			assets.resolve_asset_failure(manager, path, "$.surface_shader", data.surface_shader)
		} else {
			operation: assets.Asset_Operation = .Load
			if reload {operation = .Reload}
			assets.report_failure(manager, {kind=.Material, operation=operation, source_path=path,
				field="$.surface_shader", asset_path=data.surface_shader,
				detail="could not load or compile the surface shader; keeping the previous material when available"})
		}
	}
	return shader, shader != nil
}

material_shader_clock :: proc(settings: Scene3D_Settings, elapsed_seconds: f64) -> f32 {
	if settings.material_time_override {return settings.material_time}
	return f32(elapsed_seconds)
}

update_material_shader_time :: proc(ctx: ^Context, settings: Scene3D_Settings, elapsed_seconds: f64) {
	time := material_shader_clock(settings, elapsed_seconds)
	// R3D defers the actual draw until End; update once after all material loads,
	// including shaders first encountered during this frame's mesh submission.
	for _, asset in ctx.r3d_materials {
		if asset.shader_time {r3d.SetSurfaceShaderUniform(asset.material.shader, "u_time", &time)}
	}
}
