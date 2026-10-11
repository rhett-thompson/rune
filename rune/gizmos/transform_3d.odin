package gizmos

import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"

// Interactive world-axis handles. Layout and drag sampling are pure math;
// callers own input capture, selection, snapping preferences and persistence.
Transform_Mode :: enum {Move, Rotate}
Transform_Handle :: enum {None, X, Y, Z, Plane}
TRANSFORM_RING_SEGMENTS :: 64

Transform_Layout :: struct {
	valid: bool,
	camera: rl.Camera3D,
	pivot: [3]f32,
	screen_size: [2]f32,
	world_radius: f32,
	center: [2]f32,
	axis_ends: [3][2]f32,
	axis_visible: [3]bool,
	rings: [3][TRANSFORM_RING_SEGMENTS+1][2]f32,
	ring_visible: [3][TRANSFORM_RING_SEGMENTS+1]bool,
	ring_depths: [3][TRANSFORM_RING_SEGMENTS+1]f32,
	// Orthonormal camera frame, borrowed by the drag helpers.
	right, up, forward: [3]f32,
}

Transform_Drag :: struct {
	active: bool,
	mode: Transform_Mode,
	handle: Transform_Handle,
	layout: Transform_Layout,
	axis, normal, start_point, previous_radial: [3]f32,
	start_parameter, accumulated_angle: f32,
	// Nearly edge-on rotation rings use their projected tangent instead of
	// an unstable ray/plane intersection. The start sample remains fixed.
	screen_rotation: bool,
	start_mouse, screen_tangent: [2]f32,
}

transform_finite :: proc(value: f32) -> bool {
	return !math.is_nan(value) && !math.is_inf(value)
}

transform_vector_finite :: proc(value: [3]f32) -> bool {
	for component in value {if !transform_finite(component) {return false}}
	return true
}

transform_unit :: proc(value: [3]f32) -> ([3]f32, bool) {
	if !transform_vector_finite(value) {return {}, false}
	length := linalg.length(value)
	if length < 0.00001 || !transform_finite(length) {return {}, false}
	return value/length, true
}

transform_axis :: proc(handle: Transform_Handle) -> [3]f32 {
	#partial switch handle {
	case .X: return {1,0,0}
	case .Y: return {0,1,0}
	case .Z: return {0,0,1}
	}
	return {}
}

transform_ring_basis :: proc(axis: int) -> ([3]f32, [3]f32) {
	switch axis {
	case 0: return {0,1,0}, {0,0,1}
	case 1: return {0,0,1}, {1,0,0}
	}
	return {1,0,0}, {0,1,0}
}

// Screen coordinates match raylib's visible perspective/orthographic camera.
// Points at or behind the camera return false rather than reflecting handles.
transform_project_3d :: proc(layout: Transform_Layout, point: [3]f32) -> ([2]f32, f32, bool) {
	if !layout.valid || !transform_vector_finite(point) {return {},0,false}
	offset := point-layout.camera.position
	depth := linalg.dot(offset,layout.forward)
	if depth <= 0.001 {return {},depth,false}
	scale := layout.screen_size[1]/layout.camera.fovy
	if layout.camera.projection == .PERSPECTIVE {
		scale = layout.screen_size[1]/(2*math.tan(layout.camera.fovy*f32(math.PI/360))*depth)
	}
	point_2d := layout.screen_size*0.5 + [2]f32{linalg.dot(offset,layout.right),-linalg.dot(offset,layout.up)}*scale
	return point_2d,depth,transform_finite(point_2d[0]) && transform_finite(point_2d[1])
}

transform_layout_3d :: proc(camera: rl.Camera3D, pivot: [3]f32, screen_size: [2]f32, radius_pixels: f32 = 85) -> (Transform_Layout, bool) {
	layout := Transform_Layout{camera=camera,pivot=pivot,screen_size=screen_size}
	if !transform_vector_finite(pivot) || !transform_vector_finite(camera.position) || !transform_finite(camera.fovy) || camera.fovy<=0 || !transform_finite(radius_pixels) || radius_pixels<=0 {return {},false}
	if camera.projection != .PERSPECTIVE && camera.projection != .ORTHOGRAPHIC {return {},false}
	if camera.projection == .PERSPECTIVE && camera.fovy>=180 {return {},false}
	for component in screen_size {if !transform_finite(component) || component<=0 {return {},false}}
	forward,forward_ok := transform_unit(camera.target-camera.position)
	right,right_ok := transform_unit(linalg.cross(forward,camera.up))
	if !forward_ok || !right_ok {return {},false}
	layout.forward,layout.right,layout.up = forward,right,linalg.cross(right,forward)
	layout.valid = true
	center,depth,center_ok := transform_project_3d(layout,pivot)
	if !center_ok {return {},false}
	layout.center = center
	layout.world_radius = radius_pixels*camera.fovy/screen_size[1]
	if camera.projection == .PERSPECTIVE {
		layout.world_radius = radius_pixels*2*math.tan(camera.fovy*f32(math.PI/360))*depth/screen_size[1]
	}
	for axis in 0..<3 {
		direction := transform_axis(Transform_Handle(axis+1))
		endpoint,_,endpoint_ok := transform_project_3d(layout,pivot+direction*layout.world_radius)
		layout.axis_ends[axis] = endpoint
		// A view-aligned shaft has no stable drag parameter or useful screen
		// extent. Its other handles remain available in every camera view.
		layout.axis_visible[axis] = endpoint_ok && linalg.length(endpoint-center)>=14 && abs(linalg.dot(direction,forward))<0.985
		u,v := transform_ring_basis(axis)
		for index in 0..=TRANSFORM_RING_SEGMENTS {
			angle := f32(index)*f32(2*math.PI/TRANSFORM_RING_SEGMENTS)
			point := pivot+(u*math.cos(angle)+v*math.sin(angle))*layout.world_radius
			layout.rings[axis][index],layout.ring_depths[axis][index],layout.ring_visible[axis][index] = transform_project_3d(layout,point)
		}
	}
	return layout,true
}

transform_segment_distance :: proc(point,a,b: [2]f32) -> (f32,f32) {
	edge := b-a
	length_squared := linalg.dot(edge,edge)
	fraction := f32(0)
	if length_squared>0.0001 {fraction=clamp(linalg.dot(point-a,edge)/length_squared,0,1)}
	return linalg.length(point-a-edge*fraction),fraction
}

transform_hit_3d :: proc(layout: Transform_Layout, mode: Transform_Mode, mouse: [2]f32, tolerance: f32 = 9) -> Transform_Handle {
	if !layout.valid || !transform_finite(mouse[0]) || !transform_finite(mouse[1]) || !transform_finite(tolerance) || tolerance<=0 {return .None}
	if mode==.Move && abs(mouse[0]-layout.center[0])<=8 && abs(mouse[1]-layout.center[1])<=8 {return .Plane}
	best_distance,best_depth := tolerance,f32(1e30)
	best := Transform_Handle.None
	for axis in 0..<3 {
		if mode==.Move {
			if !layout.axis_visible[axis] {continue}
			// Reserve the middle square for the camera-plane move handle.
			edge := layout.axis_ends[axis]-layout.center
			start := layout.center+edge*(12/linalg.length(edge))
			distance,_ := transform_segment_distance(mouse,start,layout.axis_ends[axis])
			if distance<=best_distance {best_distance,best = distance,Transform_Handle(axis+1)}
		} else {
			for index in 0..<TRANSFORM_RING_SEGMENTS {
				if !layout.ring_visible[axis][index] || !layout.ring_visible[axis][index+1] {continue}
				distance,fraction := transform_segment_distance(mouse,layout.rings[axis][index],layout.rings[axis][index+1])
				depth := layout.ring_depths[axis][index]*(1-fraction)+layout.ring_depths[axis][index+1]*fraction
				if distance<=tolerance && (distance<best_distance-0.1 || (abs(distance-best_distance)<=0.1 && depth<best_depth)) {
					best_distance,best_depth,best = distance,depth,Transform_Handle(axis+1)
				}
			}
		}
	}
	return best
}

transform_handle_color :: proc(handle,hover,active: Transform_Handle) -> rl.Color {
	if handle==active {return rl.GOLD}
	if handle==hover {return rl.YELLOW}
	#partial switch handle {
	case .X: return {245,90,90,255}
	case .Y: return {90,220,125,255}
	case .Z: return {90,165,255,255}
	}
	return rl.WHITE
}

// Call outside a 3D camera mode; callers may scissor their editing viewport.
draw_transform_3d :: proc(layout: Transform_Layout, mode: Transform_Mode, hover: Transform_Handle = .None, active: Transform_Handle = .None) {
	if !layout.valid {return}
	for axis in 0..<3 {
		handle := Transform_Handle(axis+1)
		color := transform_handle_color(handle,hover,active)
		if mode==.Move {
			if !layout.axis_visible[axis] {continue}
			a,b := rl.Vector2(layout.center),rl.Vector2(layout.axis_ends[axis])
			rl.DrawLineEx(a,b,6,{10,15,22,210})
			rl.DrawLineEx(a,b,3,color)
			draw_arrow_head_2d(b,normalize2(b-a),color)
			label := cstring("X")
			if axis==1 {label="Y"} else if axis==2 {label="Z"}
			rl.DrawText(label,i32(b.x)+7,i32(b.y)-8,16,color)
		} else {
			for index in 0..<TRANSFORM_RING_SEGMENTS {
				if !layout.ring_visible[axis][index] || !layout.ring_visible[axis][index+1] {continue}
				a,b := rl.Vector2(layout.rings[axis][index]),rl.Vector2(layout.rings[axis][index+1])
				rl.DrawLineEx(a,b,5,{10,15,22,210})
				rl.DrawLineEx(a,b,2.5,color)
			}
		}
	}
	if mode==.Move {
		square := rl.Rectangle{layout.center[0]-6,layout.center[1]-6,12,12}
		rl.DrawRectangleRec(square,{20,28,35,245})
		rl.DrawRectangleLinesEx(square,2,transform_handle_color(.Plane,hover,active))
	} else {
		rl.DrawCircleV(rl.Vector2(layout.center),3,rl.WHITE)
	}
}

transform_plane_point :: proc(ray: rl.Ray, pivot, normal: [3]f32) -> ([3]f32,bool) {
	direction,valid := transform_unit(ray.direction)
	if !valid || !transform_vector_finite(ray.position) {return {},false}
	denominator := linalg.dot(direction,normal)
	if abs(denominator)<0.0001 {return {},false}
	distance := linalg.dot(pivot-ray.position,normal)/denominator
	if distance<0 || !transform_finite(distance) {return {},false}
	return ray.position+direction*distance,true
}

transform_axis_parameter :: proc(ray: rl.Ray, pivot, axis: [3]f32) -> (f32,bool) {
	direction,valid := transform_unit(ray.direction)
	if !valid || !transform_vector_finite(ray.position) {return 0,false}
	parallel := linalg.dot(axis,direction)
	denominator := 1-parallel*parallel
	if denominator<0.0005 {return 0,false}
	offset := pivot-ray.position
	parameter := (parallel*linalg.dot(direction,offset)-linalg.dot(axis,offset))/denominator
	distance := linalg.dot(direction,offset)+parallel*parameter
	return parameter,distance>=0 && transform_finite(parameter)
}

transform_ray_screen :: proc(layout: Transform_Layout, ray: rl.Ray) -> ([2]f32,bool) {
	point,valid := transform_plane_point(ray,layout.pivot,layout.forward)
	if !valid {return {},false}
	projected,_,projected_ok := transform_project_3d(layout,point)
	return projected,projected_ok
}

transform_begin_drag_3d :: proc(layout: Transform_Layout, mode: Transform_Mode, handle: Transform_Handle, ray: rl.Ray) -> (Transform_Drag,bool) {
	if !layout.valid || handle==.None || (mode==.Rotate && handle==.Plane) {return {},false}
	drag := Transform_Drag{active=true,mode=mode,handle=handle,layout=layout,axis=transform_axis(handle)}
	if mode==.Move {
		if handle==.Plane {
			drag.normal=layout.forward
			point,valid := transform_plane_point(ray,layout.pivot,drag.normal)
			if !valid {return {},false}
			drag.start_point=point
		} else {
			if !layout.axis_visible[int(handle)-1] {return {},false}
			parameter,valid := transform_axis_parameter(ray,layout.pivot,drag.axis)
			if !valid {return {},false}
			drag.start_parameter=parameter
		}
	} else {
		direction,ray_ok := transform_unit(ray.direction)
		if !ray_ok {return {},false}
		drag.normal=drag.axis
		if abs(linalg.dot(direction,drag.axis))>=0.15 {
			point,valid := transform_plane_point(ray,layout.pivot,drag.axis)
			radial,radial_ok := transform_unit(point-layout.pivot)
			if !valid || !radial_ok {return {},false}
			drag.previous_radial=radial
		} else {
			mouse,mouse_ok := transform_ray_screen(layout,ray)
			if !mouse_ok {return {},false}
			axis := int(handle)-1
			best_distance,best_depth,best_angle := f32(1e30),f32(1e30),f32(0)
			for index in 0..<TRANSFORM_RING_SEGMENTS {
				if !layout.ring_visible[axis][index] || !layout.ring_visible[axis][index+1] {continue}
				distance,fraction := transform_segment_distance(mouse,layout.rings[axis][index],layout.rings[axis][index+1])
				depth := layout.ring_depths[axis][index]*(1-fraction)+layout.ring_depths[axis][index+1]*fraction
				// Edge-on front/back arcs project onto the same segment but
				// have opposite tangents. Match picking's nearest/front rule.
				if distance<best_distance-0.1 || (abs(distance-best_distance)<=0.1 && depth<best_depth) {
					best_distance,best_depth,best_angle=distance,depth,(f32(index)+fraction)*f32(2*math.PI/TRANSFORM_RING_SEGMENTS)
				}
			}
			u,v := transform_ring_basis(axis)
			radial := u*math.cos(best_angle)+v*math.sin(best_angle)
			point := layout.pivot+radial*layout.world_radius
			tangent := (-u*math.sin(best_angle)+v*math.cos(best_angle))*layout.world_radius
			a,_,a_ok := transform_project_3d(layout,point-tangent*0.01)
			b,_,b_ok := transform_project_3d(layout,point+tangent*0.01)
			if !a_ok || !b_ok {return {},false}
			drag.screen_tangent=(b-a)/0.02
			if linalg.length(drag.screen_tangent)<4 {return {},false}
			drag.screen_rotation,drag.start_mouse=true,mouse
		}
	}
	return drag,true
}

// Returns the unsnapped displacement / signed angle from the drag baseline.
// Rotation samples accumulate wrapped differences, allowing multiple turns.
// Failed samples leave the previous valid rotation state untouched.
transform_drag_3d :: proc(drag: ^Transform_Drag, ray: rl.Ray) -> (delta: [3]f32, angle: f32, valid: bool) {
	if drag==nil || !drag.active {return {},0,false}
	if drag.mode==.Move {
		if drag.handle==.Plane {
			point,ok := transform_plane_point(ray,drag.layout.pivot,drag.normal)
			if !ok {return {},0,false}
			return point-drag.start_point,0,true
		}
		parameter,ok := transform_axis_parameter(ray,drag.layout.pivot,drag.axis)
		if !ok {return {},0,false}
		return drag.axis*(parameter-drag.start_parameter),0,true
	}
	if drag.screen_rotation {
		mouse,ok := transform_ray_screen(drag.layout,ray)
		if !ok {return {},0,false}
		angle=linalg.dot(mouse-drag.start_mouse,drag.screen_tangent)/linalg.dot(drag.screen_tangent,drag.screen_tangent)*f32(180/math.PI)
		return {},angle,transform_finite(angle)
	}
	point,ok := transform_plane_point(ray,drag.layout.pivot,drag.normal)
	radial,radial_ok := transform_unit(point-drag.layout.pivot)
	if !ok || !radial_ok {return {},0,false}
	sine := linalg.dot(drag.normal,linalg.cross(drag.previous_radial,radial))
	cosine := clamp(linalg.dot(drag.previous_radial,radial),-1,1)
	drag.accumulated_angle += math.atan2(sine,cosine)*f32(180/math.PI)
	drag.previous_radial=radial
	return {},drag.accumulated_angle,true
}

// Half increments round away from zero, symmetrically on both sides of an
// authored baseline. A nonpositive/nonfinite step disables quantization.
snap_value :: proc(value,step: f32) -> f32 {
	if !transform_finite(value) || !transform_finite(step) || step<=0 {return value}
	return math.round(value/step)*step
}

// Euler degree conversion follows ecs.compose_transform_3d's convention.
// Pre-multiplication applies the world-axis turn to the initial orientation.
// Choose equivalent Euler values close to the baseline to avoid whole-turn
// inspector jumps. Exact zero preserves the caller's authored representation.
rotate_world_3d :: proc(initial: [3]f32, handle: Transform_Handle, angle: f32) -> [3]f32 {
	axis := transform_axis(handle)
	if angle==0 || axis==([3]f32{}) || !transform_vector_finite(initial) || !transform_finite(angle) {return initial}
	radians := initial*f32(math.PI/180)
	base := linalg.quaternion_from_pitch_yaw_roll(radians[0],radians[1],radians[2])
	turn := linalg.quaternion_angle_axis(angle*f32(math.PI/180),axis)
	z,y,x := linalg.euler_angles_zyx_from_quaternion(turn*base)
	result := [3]f32{x,y,z}*f32(180/math.PI)
	alternative := [3]f32{result[0]+180,180-result[1],result[2]+180}
	for index in 0..<3 {
		result[index] += snap_value(initial[index]-result[index],360)
		alternative[index] += snap_value(initial[index]-alternative[index],360)
	}
	if linalg.dot(alternative-initial,alternative-initial)<linalg.dot(result-initial,result-initial) {return alternative}
	return result
}
