package main

import "rune:assets"
import "rune:ecs"
import "rune:geometry"
import bridge "rune:r3d_bridge"
import rl "vendor:raylib"

// Exercise the full scene path, including static geometry visibility, with
// screenshots: orthographic size is controlled by fovy rather than distance.
camera_projection_width :: proc(ctx:^bridge.Context,w:^ecs.World,manager:^assets.Asset_Manager) -> int {
	sample(ctx,w,manager)
	image:=rl.LoadImageFromScreen(); defer rl.UnloadImage(image)
	width:=0
	for x in 0..<image.width {
		color:=rl.GetImageColor(image,x,image.height/2)
		if color.r>40 && color.g>40 && color.b>40 {width+=1}
	}
	return width
}

validate_camera_projection :: proc(ctx:^bridge.Context,registry:^ecs.Component_Registry,manager:^assets.Asset_Manager) {
	w:=ecs.init(); defer ecs.destroy(&w)
	camera:=ecs.create_entity(&w)
	pose:=ecs.Transform{scale={1,1,1}}
	view:=ecs.Camera3D{active=true,target={0,0,-5},up={0,1,0},fovy=4,projection=.orthographic}
	assert(ecs.add(&w,registry,camera,pose) && ecs.add(&w,registry,camera,view))
	ambient:=ecs.create_entity(&w)
	assert(ecs.add(&w,registry,ambient,ecs.AmbientLight{color={255,255,255,255},intensity=1}))
	volume:=geometry.Volume{size={1,1,1},spacing=1,origin={-0.5,-0.5,-5.5},cells=make([]u8,1)}
	defer delete(volume.cells); volume.cells[0]=1
	colors:=[2][4]u8{{},{255,255,255,255}}
	mesh,valid:=geometry.surface(volume,colors[:]); assert(valid); defer geometry.destroy_mesh(&mesh)
	entity:=ecs.create_entity(&w)
	assert(ecs.add(&w,registry,entity,ecs.Transform{scale={1,1,1}}))
	assert(ecs.set_static_mesh(&w,entity,mesh,collidable=false))
	near:=camera_projection_width(ctx,&w,manager)
	assert(near>=59 && near<=61,"fovy=4 shows one world unit across 60 pixels at 240px height")
	pose.position[2]=5; assert(ecs.set_transform(&w,camera,pose))
	far:=camera_projection_width(ctx,&w,manager)
	assert(abs(far-near)<=1,"orthographic geometry keeps its size as the camera retreats")
	view.fovy=8; assert(ecs.set_camera_3d(&w,camera,view))
	zoomed:=camera_projection_width(ctx,&w,manager)
	assert(abs(zoomed*2-near)<=2,"doubling orthographic view height halves apparent size")
	view.projection=.perspective; view.fovy=60
	assert(ecs.set_camera_3d(&w,camera,view))
	far=camera_projection_width(ctx,&w,manager)
	pose.position[2]=0; assert(ecs.set_transform(&w,camera,pose))
	near=camera_projection_width(ctx,&w,manager)
	assert(far>0 && near*10>far*18,"perspective still scales geometry by distance after a runtime switch")
}
