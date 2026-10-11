package r3d_bridge

import "core:math"

render_scale_valid :: proc(scale: f32) -> bool {
	return !math.is_nan(scale) && !math.is_inf(scale) && scale >= 0.5 && scale <= 1
}

// Changes the automatic internal resolution on the next scene draw, after
// renderer initialization. Does not change the window or fixed resolutions.
set_render_scale :: proc(ctx: ^Context, scale: f32) -> bool {
	if ctx == nil || !render_scale_valid(scale) {return false}
	ctx.render_scale = scale
	return true
}

// Pure dimension mapping. Empty/minimized framebuffers stay empty so the
// renderer retains its previous targets until drawable dimensions return.
scaled_framebuffer_dimensions :: proc(framebuffer: [2]i32, scale: f32) -> [2]i32 {
	if framebuffer[0] <= 0 || framebuffer[1] <= 0 {return {}}
	validated_scale := scale if render_scale_valid(scale) else 1
	result: [2]i32
	for i in 0..<2 {
		result[i] = i32(clamp(math.round(f64(framebuffer[i])*f64(validated_scale)), 1, f64(framebuffer[i])))
	}
	return result
}
