package r3d_bridge

import "core:math"
import "core:testing"
import "rune:ecs"
import r3d "r3d:r3d"

@(test)
render_scale_maps_framebuffer_pixels_and_retains_empty_targets :: proc(t: ^testing.T) {
	testing.expect(t, scaled_framebuffer_dimensions({2560,1440},1) == [2]i32{2560,1440})
	testing.expect(t, scaled_framebuffer_dimensions({2560,1440},0.75) == [2]i32{1920,1080},
		"scaling uses physical framebuffer pixels rather than logical UI coordinates")
	testing.expect(t, scaled_framebuffer_dimensions({1919,1079},0.5) == [2]i32{960,540})
	testing.expect(t, scaled_framebuffer_dimensions({1,1},0.5) == [2]i32{1,1})
	for empty in ([4][2]i32{{0,720},{1280,0},{-1,720},{1280,-1}}) {
		testing.expect(t, scaled_framebuffer_dimensions(empty,0.75) == [2]i32{},
			"minimizing a window must not request zero-sized GPU targets")
	}
	for invalid in ([6]f32{0,0.49,1.01,-1,math.nan_f32(),math.inf_f32(1)}) {
		testing.expect(t, scaled_framebuffer_dimensions({1280,720},invalid) == [2]i32{1280,720},
			"uninitialized or invalid public context fields fall back to native size")
	}
}

@(test)
render_scale_setter_validates_without_changing_fixed_resolution_policy :: proc(t: ^testing.T) {
	ctx := Context{render_scale=1,match_framebuffer=false}
	testing.expect(t, set_render_scale(&ctx,0.5) && ctx.render_scale==0.5)
	testing.expect(t, !ctx.match_framebuffer,"changing scale does not enable framebuffer matching")
	testing.expect(t, set_render_scale(&ctx,0.75) && ctx.render_scale==0.75)
	for invalid in ([7]f32{0,0.49,1.01,-1,math.nan_f32(),math.inf_f32(1),math.inf_f32(-1)}) {
		testing.expect(t, !set_render_scale(&ctx,invalid) && ctx.render_scale==0.75,
			"invalid values preserve the last accepted scale")
	}
	testing.expect(t, !set_render_scale(nil,1))
	testing.expect(t, set_render_scale(&ctx,1) && ctx.render_scale==1)
}

@(test)
post_processing_override_is_complete_borrowed_and_preserves_authored_profiles :: proc(t: ^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	global:=ecs.create_entity(&w)
	global_profile:=ecs.default_post_processing(); global_profile.tonemap.exposure=0.75
	global_profile.ssgi.enabled=true
	global_profile.height_fog.enabled=true; global_profile.height_fog.density=0.025
	ecs.add(&w,&r,global,global_profile)
	camera:=ecs.create_entity(&w)
	camera_profile:=ecs.default_post_processing(); camera_profile.tonemap.exposure=1.25
	camera_profile.anti_aliasing=.smaa
	ecs.add(&w,&r,camera,camera_profile)
	selected,found:=scene_post_processing(&w,camera)
	testing.expect(t,found && selected==camera_profile,"nil retains active-camera precedence")
	override:=global_profile; override.tonemap.exposure=2; override.ssgi.enabled=false
	override.film_grain.enabled=true; override.film_grain.intensity=0.2
	override.height_fog.density=0.04
	selected,found=scene_post_processing(&w,camera,&override)
	testing.expect(t,found && selected==override,"the entire borrowed profile replaces the selected camera profile")
	env:=post_processing_environment(r3d.ENVIRONMENT_BASE,selected)
	testing.expect(t,!env.ssgi.enabled && env.tonemap.exposure==2)
	fog:=height_fog_uniforms(&w,camera,&override)
	testing.expect(t,fog.lower_params[1]==override.height_fog.density,
		"custom shader passes use the same complete override as native effects")
	selected.tonemap.exposure=7
	testing.expect(t,override.tonemap.exposure==2,"selection returns a value; the borrowed override is not mutated")
	actual_camera,_:=ecs.get_post_processing(&w,camera)
	actual_global,_:=ecs.get_post_processing(&w,global)
	testing.expect(t,actual_camera==camera_profile && actual_global==global_profile,
		"neither native mapping nor custom shader uniform preparation changes authored ECS profiles")
	selected,found=scene_post_processing(&w,camera,nil)
	testing.expect(t,found && selected==camera_profile,"removing the override immediately resumes camera selection")
	ecs.set_enabled(&w,camera,false)
	selected,found=scene_post_processing(&w,camera,nil)
	testing.expect(t,found && selected==global_profile,"nil preserves global fallback after camera disable")
}

@(test)
post_processing_disabled_and_invalid_overrides_suppress_scene_profiles :: proc(t: ^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	entity:=ecs.create_entity(&w)
	profile:=ecs.default_post_processing(); profile.height_fog.enabled=true; profile.height_fog.density=0.1
	profile.film_grain.enabled=true; profile.film_grain.intensity=0.2
	profile.light_shafts.enabled=true; profile.light_shafts.source="source"
	ecs.add(&w,&r,entity,profile)
	override:=profile; override.enabled=false
	_,found:=scene_post_processing(&w,0,&override)
	testing.expect(t,!found,"disabled overrides do not fall back to scene effects")
	fog:=height_fog_uniforms(&w,0,&override)
	testing.expect(t,fog==Height_Fog_Uniforms{})
	ctx:Context
	testing.expect(t,!prepare_film_grain(&ctx,&w,nil,0,&override))
	testing.expect(t,!prepare_height_fog(&ctx,&w,nil,0,&override))
	testing.expect(t,!prepare_light_shafts(&ctx,&w,nil,0,{},&override))
	testing.expect(t,!ctx.film_grain_attempted && !ctx.height_fog_attempted && !ctx.light_shafts_attempted,
		"disabled overrides skip lazy custom shader allocation")
	override.enabled=true; override.tonemap.exposure=math.nan_f32()
	_,found=scene_post_processing(&w,0,&override)
	testing.expect(t,!found,"invalid profiles must not send nonfinite values to GPU shaders")
	_,found=scene_post_processing(nil,0,nil); testing.expect(t,!found)
	override=ecs.default_post_processing()
	selected,valid:=scene_post_processing(nil,0,&override)
	testing.expect(t,valid && selected==override,"a valid borrowed profile requires no ECS owner")
}
