package r3d_bridge

import "core:math"
import rl "vendor:raylib"

// Keep the native projection and screen-space sample grid fixed while the
// visible lens animates. The backend clips an enlarged presentation viewport
// to the framebuffer, including its depth, without another target or pass.
@(private)
scene_sampling_projection :: proc(camera:rl.Camera3D,sampling_fovy:f32,framebuffer:[2]i32) -> (rl.Camera3D,rl.Rectangle,bool) {
	if camera.projection!=.PERSPECTIVE || framebuffer[0]<=0 || framebuffer[1]<=0 {return camera,{},false}
	if !perspective_angle_valid(camera.fovy) || !perspective_angle_valid(sampling_fovy) || sampling_fovy<=camera.fovy {return camera,{},false}
	magnification:=math.tan(f64(sampling_fovy)*math.PI/360)/math.tan(f64(camera.fovy)*math.PI/360)
	width,height:=f32(f64(framebuffer[0])*magnification),f32(f64(framebuffer[1])*magnification)
	// R3D converts the final viewport to signed integers before presenting it.
	// Reject angles whose magnification would overflow those native coordinates.
	limit:=f32(2147483520)
	if math.is_nan(width) || math.is_inf(width) || math.is_nan(height) || math.is_inf(height) || width>=limit || height>=limit {return camera,{},false}
	x,y:=sampling_viewport_origin(width,framebuffer[0]),sampling_viewport_origin(height,framebuffer[1])
	result:=camera
	result.fovy=sampling_fovy
	return result,{x,y,width,height},true
}

@(private)
perspective_angle_valid :: proc(angle:f32) -> bool {
	return !math.is_nan(angle) && !math.is_inf(angle) && angle>0 && angle<180
}

@(private)
sampling_viewport_origin :: proc(extent:f32,framebuffer:i32) -> f32 {
	// Native presentation uses int(origin+0.5), which truncates negative values
	// toward zero. Precompensate that bias and center the rounded extent. Odd
	// differences necessarily leave at most half a pixel of presentation offset.
	rounded:=i32(extent+0.5)
	origin:=-((rounded-framebuffer)/2)
	return f32(origin)-0.5 if origin<0 else f32(origin)
}
