package core

import "core:math"
import "rune:ecs"
import "rune:render"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

Debug_Pick_Dimension :: enum {None, Two_D, Three_D}
Debug_Selection_Color :: rl.Color{255,205,64,255}

clear_debug_selection :: proc(engine: ^Engine) {
	engine.debug.picked_entity = 0
	engine.debug.picked_dimension = .None
}

// Compute live native logical bounds without retaining borrowed scene data.
// Disabled entities, missing cameras, and offscreen geometry hide the marker
// while retaining selection. Console close, World replacement, or deletion clears it.
debug_selection_bounds :: proc(engine: ^Engine, screen, framebuffer: [2]f32) -> (rl.Rectangle, bool) {
	when Player_Build {return {},false}
	if engine == nil {return {},false}
	world, entity := engine.debug.world, engine.debug.picked_entity
	if !engine.console.is_open || world == nil || !ecs.is_alive(world,entity) {
		clear_debug_selection(engine)
		return {},false
	}
	if !ecs.is_enabled(world,entity) {return {},false}
	for size in ([2][2]f32{screen,framebuffer}) {
		for n in size {if n <= 0 || math.is_nan(n) || math.is_inf(n) {return {},false}}
	}
	settings := engine.project.render_2d
	if !render.resolution_valid(settings) {return {},false}
	canvas := render.canvas_dimensions(settings,screen)
	bounds: rl.Rectangle
	found := false
	switch engine.debug.picked_dimension {
	case .Two_D:
		camera_entity, component, active := ecs.active_camera_2d(world)
		pose, has_pose := ecs.get_transform(world,camera_entity)
		if !active || !has_pose {return {},false}
		camera := rl.Camera2D{offset=component.offset,target={pose.position[0],pose.position[1]},rotation=component.rotation,zoom=component.zoom}
		bounds,found = render.scene_selection_bounds_2d(world,&engine.assets,entity,camera)
	case .Three_D:
		camera_entity, component, active := ecs.active_camera_3d(world)
		_, has_pose := ecs.get_transform(world,camera_entity)
		if !active || !has_pose {return {},false}
		pose := ecs.world_transform_3d(world,camera_entity)
		camera := rl.Camera3D{position=pose.position,target=component.target,up=component.up,fovy=component.fovy,projection=rl.CameraProjection(component.projection)}
		near,far := f32(0.01),f32(1000)
		if rl.IsWindowReady() {near,far = f32(rlgl.GetCullDistanceNear()),f32(rlgl.GetCullDistanceFar())}
		bounds,found = render.scene_selection_bounds_3d(world,&engine.assets,entity,camera,canvas,near,far)
	case .None: return {},false
	}
	if !found {return {},false}
	for n in ([4]f32{bounds.x,bounds.y,bounds.width,bounds.height}) {
		if math.is_nan(n) || math.is_inf(n) {return {},false}
	}
	// Clip before mapping so selection never spills into letterbox bars.
	left,top := max(f32(0),bounds.x),max(f32(0),bounds.y)
	right,bottom := min(canvas[0],bounds.x+bounds.width),min(canvas[1],bounds.y+bounds.height)
	if right <= left || bottom <= top {return {},false}
	destination := render.resolution_rectangle(settings,framebuffer)
	scale := [2]f32{destination.width/canvas[0]*screen[0]/framebuffer[0],destination.height/canvas[1]*screen[1]/framebuffer[1]}
	offset := [2]f32{destination.x*screen[0]/framebuffer[0],destination.y*screen[1]/framebuffer[1]}
	return {offset[0]+left*scale[0],offset[1]+top*scale[1],(right-left)*scale[0],(bottom-top)*scale[1]},true
}

// Call in native screen space after game drawing and console.finish_frame,
// before console.draw. Only ordinary 2D lines are submitted: no renderer asset,
// material, shader, camera, depth, blend, or post-processing state is changed.
draw_debug_selection :: proc(engine: ^Engine) {
	when Player_Build {return}
	screen := [2]f32{f32(rl.GetScreenWidth()),f32(rl.GetScreenHeight())}
	framebuffer := [2]f32{f32(rl.GetRenderWidth()),f32(rl.GetRenderHeight())}
	bounds,visible := debug_selection_bounds(engine,screen,framebuffer)
	if !visible {return}
	destination := render.resolution_rectangle(engine.project.render_2d,framebuffer)
	viewport := rl.Rectangle{destination.x*screen[0]/framebuffer[0],destination.y*screen[1]/framebuffer[1],
		destination.width*screen[0]/framebuffer[0],destination.height*screen[1]/framebuffer[1]}
	// A little breathing room keeps the marker outside the object's surface.
	left,top := max(viewport.x+2,bounds.x-4),max(viewport.y+2,bounds.y-4)
	right,bottom := min(viewport.x+viewport.width-2,bounds.x+bounds.width+4),min(viewport.y+viewport.height-2,bounds.y+bounds.height+4)
	if right <= left || bottom <= top {return}
	length := min(f32(12),(right-left)/3,(bottom-top)/3)
	segments := [8][2][2]f32{
		{{left,top+length},{left,top}},{{left,top},{left+length,top}},
		{{right-length,top},{right,top}},{{right,top},{right,top+length}},
		{{right,bottom-length},{right,bottom}},{{right,bottom},{right-length,bottom}},
		{{left+length,bottom},{left,bottom}},{{left,bottom},{left,bottom-length}},
	}
	for segment in segments {rl.DrawLineEx(segment[0],segment[1],4,{0,0,0,220})}
	for segment in segments {rl.DrawLineEx(segment[0],segment[1],2,Debug_Selection_Color)}
}
