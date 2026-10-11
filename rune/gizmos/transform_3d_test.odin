package gizmos

import "core:math"
import "core:math/linalg"
import "core:testing"
import rl "vendor:raylib"

transform_test_camera :: proc() -> rl.Camera3D {
	return {position={0,0,10},target={0,0,0},up={0,1,0},fovy=60,projection=.PERSPECTIVE}
}

transform_test_ray :: proc(camera: rl.Camera3D, point: [3]f32) -> rl.Ray {
	return {position=camera.position,direction=point-camera.position}
}

transform_test_rotation :: proc(rotation: [3]f32, vector: [3]f32) -> [3]f32 {
	angles := rotation*f32(math.PI/180)
	q := linalg.quaternion_from_pitch_yaw_roll(angles[0],angles[1],angles[2])
	return linalg.quaternion_mul_vector3(q,vector)
}

@(test)
transform_handle_layout_preserves_screen_radius_and_projection :: proc(t: ^testing.T) {
	for size in ([3][2]f32{{1280,720},{960,540},{540,960}}) {
		for distance in ([3]f32{2,10,100}) {
			camera:=transform_test_camera(); camera.position.z=distance
			layout,ok:=transform_layout_3d(camera,{},size)
			testing.expect(t,ok && layout.center==size*0.5)
			testing.expect(t,abs(linalg.length(layout.axis_ends[0]-layout.center)-85)<0.001,"handle remains 85 pixels at every depth and viewport size")
			testing.expect(t,layout.axis_visible[0] && layout.axis_visible[1] && !layout.axis_visible[2],"view-aligned axis is not pickable")
			point,depth,valid:=transform_project_3d(layout,{1,2,0})
			expected:=size*0.5+[2]f32{1,-2}*(size[1]/(2*math.tan(f32(math.PI/6))*distance))
			testing.expect(t,valid && depth==distance && linalg.length(point-expected)<0.001)
			_,_,valid=transform_project_3d(layout,{0,0,distance+1})
			testing.expect(t,!valid,"behind-camera handles do not reflect into screen space")
		}
	}
	orthographic:=transform_test_camera(); orthographic.projection=.ORTHOGRAPHIC; orthographic.fovy=20
	layout,ok:=transform_layout_3d(orthographic,{}, {1000,500})
	testing.expect(t,ok && abs(layout.world_radius-3.4)<0.0001)
	point,_,valid:=transform_project_3d(layout,{2,4,0})
	testing.expect(t,valid && point==([2]f32{550,150}),"orthographic fovy is visible world height")
}

@(test)
transform_handle_layout_rejects_invalid_cameras_and_sizes :: proc(t: ^testing.T) {
	camera:=transform_test_camera()
	for size in ([4][2]f32{{0,720},{1280,-1},{math.nan_f32(),720},{1280,math.inf_f32(1)}}) {
		_,ok:=transform_layout_3d(camera,{},size); testing.expect(t,!ok)
	}
	for fovy in ([5]f32{0,-1,180,math.nan_f32(),math.inf_f32(1)}) {
		invalid:=camera; invalid.fovy=fovy
		_,ok:=transform_layout_3d(invalid,{}, {1280,720}); testing.expect(t,!ok)
	}
	invalid:=camera; invalid.up={0,0,1}
	_,ok:=transform_layout_3d(invalid,{}, {1280,720}); testing.expect(t,!ok,"parallel camera up has no screen basis")
	invalid=camera; invalid.target=invalid.position
	_,ok=transform_layout_3d(invalid,{}, {1280,720}); testing.expect(t,!ok)
	_,ok=transform_layout_3d(camera,{0,0,11}, {1280,720}); testing.expect(t,!ok)
}

@(test)
transform_handle_picking_reserves_center_and_chooses_nearest_shaft :: proc(t: ^testing.T) {
	layout,ok:=transform_layout_3d(transform_test_camera(),{}, {1280,720}); testing.expect(t,ok)
	testing.expect(t,transform_hit_3d(layout,.Move,layout.center)==.Plane)
	testing.expect(t,transform_hit_3d(layout,.Move,layout.center+[2]f32{50,2})==.X)
	testing.expect(t,transform_hit_3d(layout,.Move,layout.center+[2]f32{2,-50})==.Y)
	testing.expect(t,transform_hit_3d(layout,.Move,layout.center+[2]f32{50,-50})==.None)
	testing.expect(t,transform_hit_3d(layout,.Move,layout.center+[2]f32{100,0})==.None)
	testing.expect(t,transform_hit_3d(layout,.Rotate,layout.center)==.None || transform_hit_3d(layout,.Rotate,layout.center)==.X || transform_hit_3d(layout,.Rotate,layout.center)==.Y,"rotation never exposes camera-plane move handle")
	// Ring intersections are resolved by frontmost segment rather than axis order.
	layout.rings={}; layout.ring_visible={}; layout.ring_depths={}
	for axis in 0..<3 {
		layout.rings[axis][0]={100,100}; layout.rings[axis][1]={200,100}
		layout.ring_visible[axis][0],layout.ring_visible[axis][1]=true,true
		layout.ring_depths[axis][0],layout.ring_depths[axis][1]=f32(10-axis),f32(10-axis)
	}
	testing.expect(t,transform_hit_3d(layout,.Rotate,{150,100})==.Z,"closest visible ring wins at equal pixel distance")
	layout.rings[2][0][1]=105; layout.rings[2][1][1]=105
	testing.expect(t,transform_hit_3d(layout,.Rotate,{150,100})==.Y,"pixel distance takes precedence over depth")
}

@(test)
transform_axis_drag_retains_only_world_axis_and_baseline :: proc(t: ^testing.T) {
	camera:=transform_test_camera(); camera.position={6,4,10}
	layout,ok:=transform_layout_3d(camera,{2,3,-1},{1280,720}); testing.expect(t,ok)
	start:=layout.pivot+[3]f32{0.6,0,0}
	drag,began:=transform_begin_drag_3d(layout,.Move,.X,transform_test_ray(camera,start)); testing.expect(t,began)
	delta,angle,valid:=transform_drag_3d(&drag,transform_test_ray(camera,start+[3]f32{-1.75,0,0}))
	testing.expect(t,valid && abs(delta[0]+1.75)<0.00001 && delta[1]==0 && delta[2]==0 && angle==0)
	delta,_,valid=transform_drag_3d(&drag,transform_test_ray(camera,start+[3]f32{0.21,0,0}))
	testing.expect(t,valid && abs(delta[0]-0.21)<0.00001,"drag result is absolute from the initial sample, independent of applied/snapped previews")
	_,_,valid=transform_drag_3d(&drag,{position=camera.position,direction={1,0,0}})
	testing.expect(t,!valid,"axis-parallel sample is ignored without producing huge displacement")
	_,_,valid=transform_drag_3d(&drag,{position=camera.position,direction={}}); testing.expect(t,!valid)
	_,began=transform_begin_drag_3d(layout,.Move,.X,{position=camera.position,direction={1,0,0}}); testing.expect(t,!began)
}

@(test)
transform_plane_drag_matches_frozen_camera_plane_and_rejects_backward_rays :: proc(t: ^testing.T) {
	camera:=transform_test_camera(); camera.position={7,5,11}
	layout,ok:=transform_layout_3d(camera,{1,2,3},{1280,720}); testing.expect(t,ok)
	drag,began:=transform_begin_drag_3d(layout,.Move,.Plane,transform_test_ray(camera,layout.pivot)); testing.expect(t,began)
	expected:=layout.right*1.31+layout.up*(-0.62)
	delta,_,valid:=transform_drag_3d(&drag,transform_test_ray(camera,layout.pivot+expected))
	testing.expect(t,valid && linalg.length(delta-expected)<0.00001 && abs(linalg.dot(delta,layout.forward))<0.00001)
	_,_,valid=transform_drag_3d(&drag,{position=camera.position,direction=-layout.forward}); testing.expect(t,!valid)
	_,_,valid=transform_drag_3d(&drag,{position=camera.position,direction=layout.right}); testing.expect(t,!valid)
}

@(test)
transform_rotation_drag_sign_and_unwrap_allow_multiple_turns :: proc(t: ^testing.T) {
	camera:=transform_test_camera()
	layout,ok:=transform_layout_3d(camera,{}, {1280,720}); testing.expect(t,ok)
	drag,began:=transform_begin_drag_3d(layout,.Rotate,.Z,transform_test_ray(camera,{layout.world_radius,0,0})); testing.expect(t,began && !drag.screen_rotation)
	for degrees in ([4]f32{100,200,300,400}) {
		angle:=degrees*f32(math.PI/180)
		_,actual,valid:=transform_drag_3d(&drag,transform_test_ray(camera,{math.cos(angle)*layout.world_radius,math.sin(angle)*layout.world_radius,0}))
		testing.expect(t,valid && abs(actual-degrees)<0.0001,"positive Z turns from +X toward +Y and unwraps across +/-180")
	}
	before:=drag.accumulated_angle
	_,_,valid:=transform_drag_3d(&drag,transform_test_ray(camera,layout.pivot))
	testing.expect(t,!valid && drag.accumulated_angle==before,"invalid center sample retains the preceding valid radial")
}

@(test)
transform_edge_on_rotation_uses_finite_screen_tangent :: proc(t: ^testing.T) {
	camera:=transform_test_camera(); camera.projection=.ORTHOGRAPHIC; camera.fovy=10
	layout,ok:=transform_layout_3d(camera,{}, {1280,720}); testing.expect(t,ok)
	start:=[3]f32{0,layout.world_radius*0.5,0}
	ray:=rl.Ray{position={0,start[1],10},direction={0,0,-1}}
	drag,began:=transform_begin_drag_3d(layout,.Rotate,.X,ray)
	testing.expect(t,began && drag.screen_rotation,"an exactly edge-on ring has a usable tangent fallback")
	ray.position.y+=0.25
	_,angle,valid:=transform_drag_3d(&drag,ray)
	testing.expect(t,valid && transform_finite(angle) && abs(angle)>1)
	_,angle_again,valid_again:=transform_drag_3d(&drag,ray)
	testing.expect(t,valid_again && angle_again==angle,"screen fallback also samples from a fixed baseline")
}

@(test)
transform_edge_on_rotation_chooses_front_arc_from_either_side :: proc(t: ^testing.T) {
	for side in ([2]f32{-1,1}) {
		camera:=transform_test_camera(); camera.position.z=side*10
		camera.projection=.ORTHOGRAPHIC; camera.fovy=10
		layout,ok:=transform_layout_3d(camera,{}, {1280,720}); testing.expect(t,ok)
		// Positive and negative Z ring arcs have identical projected Y at
		// this point. Their tangents have opposite signs. From -Z the first
		// segment visited is the farther arc, so order-only selection fails.
		ray:=rl.Ray{position={0,layout.world_radius*0.5,side*10},direction={0,0,-side}}
		drag,began:=transform_begin_drag_3d(layout,.Rotate,.X,ray)
		testing.expect(t,began && drag.screen_rotation)
		testing.expect(t,drag.screen_tangent[1]*side>0,"the front arc determines the projected tangent on both camera sides")
		ray.position.y+=0.25
		_,angle,valid:=transform_drag_3d(&drag,ray)
		testing.expect(t,valid && angle*side<0,"moving the front arc upward produces the physically matching world-X turn")
	}
}

@(test)
transform_snap_is_signed_and_does_not_quantize_invalid_steps :: proc(t: ^testing.T) {
	expectations := [8]f32{-1.5,-1,-0.5,-0.5,0.5,0.5,1,1.5}
	for value,index in ([8]f32{-1.26,-0.75,-0.26,-0.25,0.25,0.26,0.75,1.26}) {
		expected:=expectations[index]
		testing.expect(t,snap_value(value,0.5)==expected,"snap grid is symmetric about the baseline")
	}
	for step in ([4]f32{0,-1,math.nan_f32(),math.inf_f32(1)}) {testing.expect(t,snap_value(1.23,step)==1.23)}
	testing.expect(t,snap_value(7.6,15)==15 && snap_value(-7.6,15)==-15)
}

@(test)
transform_world_rotation_composes_mixed_axes_and_preserves_noop :: proc(t: ^testing.T) {
	for initial in ([6][3]f32{{0,0,0},{20,30,40},{70,-50,10},{0,90,0},{10,89.99,30},{360,270,-180}}) {
		for handle in ([3]Transform_Handle{.X,.Y,.Z}) {
			testing.expect(t,rotate_world_3d(initial,handle,0)==initial,"zero drag leaves the exact authored Euler representation")
			for angle in ([5]f32{-90,-17,17,90,270}) {
				actual:=rotate_world_3d(initial,handle,angle)
				turn:=linalg.quaternion_angle_axis(angle*f32(math.PI/180),transform_axis(handle))
				for vector in ([3][3]f32{{1,0,0},{0,1,0},{0,0,1}}) {
					expected:=linalg.quaternion_mul_vector3(turn,transform_test_rotation(initial,vector))
					testing.expect(t,linalg.length(transform_test_rotation(actual,vector)-expected)<0.001,"world rotation composes orientation rather than incrementing an Euler component")
				}
			}
		}
	}
}
