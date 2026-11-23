package r3d_bridge

import "core:testing"
import "rune:ecs"
import r3d "r3d:r3d"
import rl "vendor:raylib"

@(test)
scene_camera_origin_inherits_hierarchy_with_world_target_and_up :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r)
	testing.expect(t,ecs.register_builtin_components(&r))
	root:=ecs.create_entity(&w)
	ecs.add(&w,&r,root,ecs.Transform{position={10,20,30},rotation={0,90,0},scale={2,3,4}})
	gap:=ecs.create_entity(&w); ecs.set_parent(&w,gap,root)
	entity:=ecs.create_entity(&w); ecs.set_parent(&w,entity,gap)
	ecs.add(&w,&r,entity,ecs.Transform{position={1,2,3},rotation={40,50,60},scale={2,3,4}})
	value:=ecs.Camera3D{target={5,6,7},up={0,0,1},fovy=6,projection=.orthographic}
	camera,valid:=scene_camera_3d(&w,entity,value)
	testing.expect(t,valid)
	expected:=[3]f32{22,26,28}
	for axis in 0..<3 {testing.expect(t,abs(camera.position[axis]-expected[axis])<0.001)}
	testing.expect(t,camera.target==value.target && camera.up==value.up,
		"explicit world-space target and up must not inherit entity rotations")
	testing.expect(t,camera.fovy==6 && camera.projection==.ORTHOGRAPHIC,
		"orthographic height is already expressed in world units")
	w.transforms[root]=ecs.Transform{position={-10,0,5},rotation={0,180,0},scale={3,2,1}}
	camera,valid=scene_camera_3d(&w,entity,value)
	expected={-13,4,2}
	for axis in 0..<3 {testing.expect(t,abs(camera.position[axis]-expected[axis])<0.001)}
	testing.expect(t,valid && camera.target==value.target && camera.up==value.up)
	ecs.set_parent(&w,entity,0)
	camera,valid=scene_camera_3d(&w,entity,value)
	testing.expect(t,valid && camera.position==[3]f32{1,2,3},"unparented cameras retain their original position")
	missing:=ecs.create_entity(&w)
	_,valid=scene_camera_3d(&w,missing,value)
	testing.expect(t,!valid,"camera still requires its own Transform component")
}

@(test)
scene_view_aspects_follow_the_sampling_viewport_and_internal_target :: proc(t:^testing.T) {
	main,auxiliary,valid:=scene_view_aspects({}, {1920,1080}, {1280,800}, .EXPAND)
	testing.expect(t,valid && main==1920.0/1080.0 && auxiliary==1.6)
	main,auxiliary,valid=scene_view_aspects({width=2560,height=1440}, {1920,1080}, {1280,800}, .KEEP)
	testing.expect(t,valid && main==auxiliary && auxiliary==1.6)
	_,_,valid=scene_view_aspects({}, {0,1080}, {1280,800}, .KEEP)
	testing.expect(t,!valid)
}

@(test)
frustum_box_test_retains_crossing_and_unavailable_bounds :: proc(t:^testing.T) {
	camera:=r3d.Camera{fovy=60,nearPlane=0.1,farPlane=250,projection=.PERSPECTIVE}
	r3d.CameraLookAt(&camera,{0,0,-1},{0,1,0})
	frustum:=r3d.ComputeFrustum(r3d.GetCameraViewProj(camera,1))
	local:=rl.BoundingBox{{-0.1,-0.1,-10},{0.1,0.1,10}}
	pose:=ecs.Transform{position={35,0,-15},scale={1,1,4}}
	testing.expect(t,!frustum_may_intersect_transformed_box(&frustum,local,pose))
	pose.rotation={0,45,0}
	testing.expect(t,frustum_may_intersect_transformed_box(&frustum,local,pose),"the rotated long box crosses the camera even with an offscreen center")
	testing.expect(t,frustum_may_intersect_transformed_box(nil,local,pose))
	testing.expect(t,frustum_may_intersect_transformed_box(&frustum,{{1,1,1},{0,0,0}},pose))
}

@(test)
frustum_box_test_pads_mirrored_off_center_bounds :: proc(t:^testing.T) {
	camera:=r3d.Camera{fovy=10,nearPlane=0.1,farPlane=250,projection=.ORTHOGRAPHIC}
	r3d.CameraLookAt(&camera,{0,0,-1},{0,1,0})
	frustum:=r3d.ComputeFrustum(r3d.GetCameraViewProj(camera,1))
	local:=rl.BoundingBox{{1,-0.5,-0.5},{3,0.5,0.5}}
	pose:=ecs.Transform{position={11.005,0,-4},scale={-2,1,0.5}}
	identity:=rl.Quaternion(1)
	for cached in ([2]^rl.Quaternion{nil,&identity}) {
		testing.expect(t,frustum_may_intersect_box_at_pose(&frustum,local,pose,cached),"the padded box still reaches the right clip plane")
		outside:=pose
		outside.position.x=11.03
		testing.expect(t,!frustum_may_intersect_box_at_pose(&frustum,local,outside,cached))
	}
}
