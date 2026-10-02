package r3d_bridge

import "core:math"
import "core:strings"
import "rune:assets"
import "rune:ecs"
import r3d "r3d:r3d"

prepare_height_fog :: proc(ctx: ^Context, world: ^ecs.World, manager: ^assets.Asset_Manager, camera: ecs.Entity) -> bool {
	profile, found := ecs.active_post_processing(world, camera)
	if !found {return false}
	lower,upper:=profile.height_fog,profile.upper_height_fog
	if !lower.enabled {lower.density=0}
	if !upper.enabled {upper.density=0}
	if lower.density<=0 && upper.density<=0 {return false}
	if !ctx.height_fog_attempted {
		ctx.height_fog_attempted = true
		source :: #load("height_fog.glsl", string)
		ctx.height_fog_shader = r3d.LoadScreenShaderFromMemory(strings.clone_to_cstring(source, context.temp_allocator))
		if ctx.height_fog_shader == nil {
			assets.report_failure(manager, {kind = .PostProcessing, field = "PostProcessing.height_fog",
				detail = "could not load height fog shader"})
		} else {assets.resolve_asset_failure(manager, "", "PostProcessing.height_fog", "")}
	}
	if ctx.height_fog_shader == nil {return false}
	// SCENE colors are linear; match r3d's sRGB fog color conversion.
	color,upper_color: [3]f32
	for i in 0..<3 {
		color[i] = math.pow(f32(lower.color[i])/255, 2.2)
		upper_color[i] = math.pow(f32(upper.color[i])/255, 2.2)
	}
	params:=[4]f32{lower.base_height,lower.density,lower.falloff,lower.sky_distance}
	upper_params:=[4]f32{upper.base_height,upper.density,-upper.falloff,upper.sky_distance}
	r3d.SetScreenShaderUniform(ctx.height_fog_shader, "u_color", &color)
	r3d.SetScreenShaderUniform(ctx.height_fog_shader, "u_params", &params)
	r3d.SetScreenShaderUniform(ctx.height_fog_shader, "u_upper_color", &upper_color)
	r3d.SetScreenShaderUniform(ctx.height_fog_shader, "u_upper_params", &upper_params)
	return true
}
