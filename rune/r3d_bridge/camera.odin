package r3d_bridge

import "rune:ecs"
import rl "vendor:raylib"

// Camera origins follow the rendered hierarchy. Target and up remain explicit
// world-space vectors, independent of the entity's rotation and scale.
scene_camera_3d :: proc(world:^ecs.World,entity:ecs.Entity,value:ecs.Camera3D) -> (rl.Camera3D,bool) {
	_,has_transform:=ecs.get_transform(world,entity)
	if !has_transform {return {},false}
	return rl.Camera3D{
		position=ecs.world_transform_3d(world,entity).position,
		target=value.target,
		up=value.up,
		fovy=value.fovy,
		projection=rl.CameraProjection(value.projection),
	},true
}
