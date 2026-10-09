package core

import "core:testing"
import "rune:ecs"

@(test)
orbit_camera_keeps_world_target_under_nested_parent_transforms :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r)
	testing.expect(t,ecs.register_builtin_components(&r))
	root:=ecs.create_entity(&w)
	testing.expect(t,ecs.add(&w,&r,root,ecs.Transform{position={10,2,-5},rotation={0,90,0},scale={2,3,4}}))
	gap:=ecs.create_entity(&w); testing.expect(t,ecs.set_parent(&w,gap,root))
	branch:=ecs.create_entity(&w); testing.expect(t,ecs.set_parent(&w,branch,gap))
	testing.expect(t,ecs.add(&w,&r,branch,ecs.Transform{position={1,2,3},rotation={0,90,0},scale={0.5,2,1}}))
	entity:=ecs.create_entity(&w); testing.expect(t,ecs.set_parent(&w,entity,branch))
	testing.expect(t,ecs.add(&w,&r,entity,ecs.Transform{position={3,4,5},scale={1,1,1}}))
	camera:=ecs.default_camera_3d(); camera.up={0,0,1}
	testing.expect(t,ecs.add(&w,&r,entity,camera))
	orbit:=ecs.default_orbit_camera_3d()
	orbit.target={5,2,7}; orbit.yaw=0; orbit.pitch=0; orbit.distance=10; orbit.auto_yaw_speed=90
	testing.expect(t,ecs.add(&w,&r,entity,orbit))
	engine:=Engine{delta_time=1}
	update_orbit_cameras_3d(&engine,&w)
	world_pose:=ecs.world_transform_3d(&w,entity)
	expected:=[3]f32{5,2,17}
	for axis in 0..<3 {testing.expect(t,abs(world_pose.position[axis]-expected[axis])<0.001)}
	local,_:=ecs.get_transform(&w,entity)
	expected_local:=[3]f32{17,-1,-6}
	for axis in 0..<3 {testing.expect(t,abs(local.position[axis]-expected_local[axis])<0.001)}
	view,_:=ecs.get_camera_3d(&w,entity)
	testing.expect(t,view.target==orbit.target && view.up==camera.up,"target and up retain explicit world coordinates")
	// The camera keeps orbiting its world target even when its hierarchy moves.
	engine.delta_time=0
	pose,_:=ecs.get_transform(&w,root); pose.position+={-4,1,2}
	testing.expect(t,ecs.set_transform(&w,root,pose))
	update_orbit_cameras_3d(&engine,&w)
	world_pose=ecs.world_transform_3d(&w,entity)
	for axis in 0..<3 {testing.expect(t,abs(world_pose.position[axis]-expected[axis])<0.001)}
	// Mirrored parent scales are invertible; a collapsed axis is not.
	pose.scale.x=-2; testing.expect(t,ecs.set_transform(&w,root,pose))
	update_orbit_cameras_3d(&engine,&w)
	world_pose=ecs.world_transform_3d(&w,entity)
	for axis in 0..<3 {testing.expect(t,abs(world_pose.position[axis]-expected[axis])<0.001)}
	before_pose,_:=ecs.get_transform(&w,entity)
	before_orbit,_:=ecs.get_orbit_camera_3d(&w,entity)
	before_camera,_:=ecs.get_camera_3d(&w,entity)
	pose.scale.x=0; testing.expect(t,ecs.set_transform(&w,root,pose))
	engine.delta_time=1
	update_orbit_cameras_3d(&engine,&w)
	after_pose,_:=ecs.get_transform(&w,entity)
	after_orbit,_:=ecs.get_orbit_camera_3d(&w,entity)
	after_camera,_:=ecs.get_camera_3d(&w,entity)
	testing.expect(t,after_pose==before_pose && after_orbit==before_orbit && after_camera==before_camera,
		"a singular parent skips the update without committing invalid pose or orbit state")
	// A root camera still receives the unmodified world-space orbit result.
	testing.expect(t,ecs.set_parent(&w,entity,0))
	update_orbit_cameras_3d(&engine,&w)
	world_pose=ecs.world_transform_3d(&w,entity)
	expected={-5,2,7}
	for axis in 0..<3 {testing.expect(t,abs(world_pose.position[axis]-expected[axis])<0.001)}
}
