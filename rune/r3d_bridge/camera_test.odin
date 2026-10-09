package r3d_bridge

import "core:testing"
import "rune:ecs"

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
