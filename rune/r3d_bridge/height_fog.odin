package r3d_bridge

import "core:math"
import "core:strings"
import "rune:assets"
import "rune:ecs"
import r3d "r3d:r3d"

Height_Fog_Uniforms :: struct {
	lower_color,upper_color:[3]f32,
	lower_params,upper_params:[4]f32,
}

height_fog_uniforms :: proc(world:^ecs.World,camera:ecs.Entity) -> Height_Fog_Uniforms {
	profile,found:=ecs.active_post_processing(world,camera)
	if !found {return {}}
	lower,upper:=profile.height_fog,profile.upper_height_fog
	if !lower.enabled {lower.density=0}
	if !upper.enabled {upper.density=0}
	uniforms:Height_Fog_Uniforms
	for i in 0..<3 {
		uniforms.lower_color[i]=math.pow(f32(lower.color[i])/255,2.2)
		uniforms.upper_color[i]=math.pow(f32(upper.color[i])/255,2.2)
	}
	uniforms.lower_params={lower.base_height,lower.density,lower.falloff,lower.sky_distance}
	uniforms.upper_params={upper.base_height,upper.density,-upper.falloff,upper.sky_distance}
	return uniforms
}

prepare_height_fog :: proc(ctx: ^Context, world: ^ecs.World, manager: ^assets.Asset_Manager, camera: ecs.Entity) -> bool {
	uniforms:=height_fog_uniforms(world,camera)
	if uniforms.lower_params[1]<=0 && uniforms.upper_params[1]<=0 {return false}
	if !ctx.height_fog_attempted {
		ctx.height_fog_attempted = true
		source :: #load("height_fog_common.glsl",string)+#load("height_fog.glsl", string)
		ctx.height_fog_shader = r3d.LoadScreenShaderFromMemory(strings.clone_to_cstring(source, context.temp_allocator))
		if ctx.height_fog_shader == nil {
			assets.report_failure(manager, {kind = .PostProcessing, field = "PostProcessing.height_fog",
				detail = "could not load height fog shader"})
		} else {assets.resolve_asset_failure(manager, "", "PostProcessing.height_fog", "")}
	}
	if ctx.height_fog_shader == nil {return false}
	r3d.SetScreenShaderUniform(ctx.height_fog_shader, "u_color", &uniforms.lower_color)
	r3d.SetScreenShaderUniform(ctx.height_fog_shader, "u_params", &uniforms.lower_params)
	r3d.SetScreenShaderUniform(ctx.height_fog_shader, "u_upper_color", &uniforms.upper_color)
	r3d.SetScreenShaderUniform(ctx.height_fog_shader, "u_upper_params", &uniforms.upper_params)
	return true
}
