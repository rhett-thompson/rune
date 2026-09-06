package core

import "rune:render"
import rl "vendor:raylib"

set_resolution_2d :: proc(engine: ^Engine, settings: render.Resolution_Settings) -> bool {
	if engine == nil || !render.resolution_valid(settings) || engine.canvas.active {return false}
	engine.project.render_2d = settings
	return true
}

canvas_size :: proc(engine: ^Engine) -> [2]f32 {
	return render.canvas_dimensions(engine.project.render_2d,{f32(rl.GetScreenWidth()),f32(rl.GetScreenHeight())})
}

// Use the returned inside flag to ignore mouse clicks in the letterbox bars.
mouse_canvas_position :: proc(engine: ^Engine) -> ([2]f32,bool) {
	return render.screen_to_canvas(engine.project.render_2d,
		{f32(rl.GetScreenWidth()),f32(rl.GetScreenHeight())},
		{f32(rl.GetRenderWidth()),f32(rl.GetRenderHeight())},rl.GetMousePosition())
}
