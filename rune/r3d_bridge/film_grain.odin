package r3d_bridge

import "core:math"
import "core:strings"
import "rune:assets"
import "rune:ecs"
import r3d "r3d:r3d"
import rl "vendor:raylib"

prepare_film_grain :: proc(ctx: ^Context, world: ^ecs.World, manager: ^assets.Asset_Manager, camera: ecs.Entity) -> bool {
	profile,found:=ecs.active_post_processing(world,camera)
	if !found || !profile.film_grain.enabled || profile.film_grain.intensity<=0 {return false}
	if !ctx.film_grain_attempted {
		ctx.film_grain_attempted=true
		source :: #load("film_grain.glsl",string)
		ctx.film_grain_shader=r3d.LoadScreenShaderFromMemory(strings.clone_to_cstring(source,context.temp_allocator))
		if ctx.film_grain_shader==nil {
			assets.report_failure(manager,{kind=.PostProcessing,field="PostProcessing.film_grain",detail="could not load film grain shader"})
		} else {assets.resolve_asset_failure(manager,"","PostProcessing.film_grain","")}
	}
	if ctx.film_grain_shader==nil {return false}
	grain:=profile.film_grain
	// Bound before f32 conversion so a long-running session retains frame changes.
	phase:=f32(math.mod(math.floor(rl.GetTime()*f64(grain.speed)),f64(65536)))
	params:=[3]f32{grain.intensity,grain.size,phase}
	r3d.SetScreenShaderUniform(ctx.film_grain_shader,"u_grain",&params)
	return true
}
