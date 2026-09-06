package render

import "core:math"
import rl "vendor:raylib"

Resolution_Policy :: enum {native, fit, stretch, integer}
Resolution_Settings :: struct {policy: Resolution_Policy, width, height: i32}
Canvas :: struct {target: rl.RenderTexture2D, destination: rl.Rectangle, active: bool}

@(private)
active_canvas_size: [2]f32

resolution_valid :: proc(settings: Resolution_Settings) -> bool {
	return settings.policy >= .native && settings.policy <= .integer &&
		(settings.policy == .native || (settings.width > 0 && settings.height > 0 && settings.width <= 8192 && settings.height <= 8192))
}

// Destination in physical pixels. Integer mode falls back to fit below 1x.
resolution_rectangle :: proc(settings: Resolution_Settings, framebuffer: [2]f32) -> rl.Rectangle {
	if !resolution_valid(settings) || framebuffer[0] <= 0 || framebuffer[1] <= 0 {return {}}
	if settings.policy == .native || settings.policy == .stretch {return {0,0,framebuffer[0],framebuffer[1]}}
	w,h := f32(settings.width),f32(settings.height)
	scale := min(framebuffer[0]/w,framebuffer[1]/h)
	if settings.policy == .integer && scale >= 1 {scale = math.floor(scale)}
	w *= scale; h *= scale
	x,y := (framebuffer[0]-w)/2,(framebuffer[1]-h)/2
	if settings.policy == .integer {x=math.floor(x); y=math.floor(y)}
	return {x,y,w,h}
}

canvas_dimensions :: proc(settings: Resolution_Settings, screen: [2]f32) -> [2]f32 {
	return screen if settings.policy == .native else [2]f32{f32(settings.width),f32(settings.height)}
}

// Convert raylib's logical mouse coordinates into the reference canvas.
screen_to_canvas :: proc(settings: Resolution_Settings, screen, framebuffer, point: [2]f32) -> ([2]f32,bool) {
	if screen[0] <= 0 || screen[1] <= 0 {return {},false}
	rect := resolution_rectangle(settings,framebuffer)
	if rect.width <= 0 || rect.height <= 0 {return {},false}
	p := [2]f32{point[0]*framebuffer[0]/screen[0],point[1]*framebuffer[1]/screen[1]}
	size := canvas_dimensions(settings,screen)
	return {(p[0]-rect.x)*size[0]/rect.width,(p[1]-rect.y)*size[1]/rect.height},
		p[0]>=rect.x && p[1]>=rect.y && p[0]<rect.x+rect.width && p[1]<rect.y+rect.height
}

// Scene renderers use the virtual viewport for culling while a canvas is active.
drawing_size :: proc() -> [2]f32 {
	if active_canvas_size[0] > 0 {return active_canvas_size}
	return {f32(rl.GetScreenWidth()),f32(rl.GetScreenHeight())}
}

begin_canvas :: proc(canvas: ^Canvas, settings: Resolution_Settings) -> bool {
	if canvas.active || active_canvas_size[0] > 0 || !resolution_valid(settings) {return false}
	if settings.policy == .native {return true}
	if canvas.target.texture.width != settings.width || canvas.target.texture.height != settings.height {
		destroy_canvas(canvas)
		canvas.target = rl.LoadRenderTexture(settings.width,settings.height)
	}
	if canvas.target.id == 0 {return false}
	rl.SetTextureFilter(canvas.target.texture,.POINT if settings.policy == .integer else .BILINEAR)
	rect := resolution_rectangle(settings,{f32(rl.GetRenderWidth()),f32(rl.GetRenderHeight())})
	sx,sy := f32(rl.GetScreenWidth())/f32(rl.GetRenderWidth()),f32(rl.GetScreenHeight())/f32(rl.GetRenderHeight())
	canvas.destination = {rect.x*sx,rect.y*sy,rect.width*sx,rect.height*sy}
	canvas.active = true
	active_canvas_size = {f32(settings.width),f32(settings.height)}
	rl.BeginTextureMode(canvas.target)
	return true
}

end_canvas :: proc(canvas: ^Canvas) {
	if !canvas.active {return}
	rl.EndTextureMode()
	canvas.active = false
	active_canvas_size = {}
	rl.ClearBackground(rl.BLACK)
	rl.DrawTexturePro(canvas.target.texture,{0,0,f32(canvas.target.texture.width),-f32(canvas.target.texture.height)},canvas.destination,{},0,rl.WHITE)
}

destroy_canvas :: proc(canvas: ^Canvas) {
	if canvas.active {end_canvas(canvas)}
	if canvas.target.id != 0 {rl.UnloadRenderTexture(canvas.target)}
	canvas^ = {}
}
