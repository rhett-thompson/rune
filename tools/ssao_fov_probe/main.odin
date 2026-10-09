package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "rune:assets"
import "rune:ecs"
import bridge "rune:r3d_bridge"
import r3d "r3d:r3d"
import rl "vendor:raylib"

Output: string = "build/ssao-fov-probe"

Sample :: struct {
	point: [3]f32,
	pixel: [2]int,
	on, off, drop: f64,
}
Result :: struct {
	label: string,
	scene: string,
	width, height: i32,
	fovy: f32,
	authored_max_radius, ssao_reference_fovy: f32,
	compensated: bool,
	ssao_enabled: bool,
	corner_drop, floor_drop, wall_drop: f64,
	max_floor_drop, max_wall_drop: f64,
	corner, floor, wall: [dynamic]Sample,
	on_path, off_path: string,
}
Sweep :: struct {
	scene: string,
	width, height: i32,
	compensated: bool,
	base_floor_drop, sprint_floor_drop, max_floor_shift, relative_floor_shift: f64,
	base_corner_drop, sprint_corner_drop, max_corner_shift: f64,
	return_changed_pixels: int,
}

luma :: proc(color: rl.Color) -> f64 {
	return 0.2126*f64(color.r)+0.7152*f64(color.g)+0.0722*f64(color.b)
}

// Comparing the same world positions separates actual AO changes from the
// expected screen-space movement of geometry when the projection widens.
sample :: proc(on, off: rl.Image, point: [3]f32, camera: rl.Camera3D, width, height: i32) -> Sample {
	pixel:=rl.GetWorldToScreenEx(point,camera,width,height)
	x,y:=int(pixel.x),int(pixel.y)
	assert(x>=2 && x<int(width)-2 && y>=2 && y<int(height)-2)
	result:=Sample{point=point,pixel={x,y}}
	for dy in -1..=1 {for dx in -1..=1 {
		result.on+=luma(rl.GetImageColor(on,i32(x+dx),i32(y+dy)))/9
		result.off+=luma(rl.GetImageColor(off,i32(x+dx),i32(y+dy)))/9
	}}
	result.drop=result.off-result.on
	return result
}

render :: proc(ctx: ^bridge.Context, world: ^ecs.World, manager: ^assets.Asset_Manager, path: string, reference_fovy: f32) -> rl.Image {
	for _ in 0..<4 {
		rl.BeginDrawing()
		rl.ClearBackground({15,19,24,255})
		assert(bridge.draw_scene_ex(ctx,world,manager,{background_color={15,19,24,255},ssao_reference_fovy=reference_fovy}))
		assert(r3d.GetEnvironment().ssao.maxRadius==0.2,"draw-scoped FOV compensation must restore the native authored radius cap")
		rl.EndDrawing()
	}
	image:=rl.LoadImageFromScreen()
	assert(rl.ExportImage(image,strings.clone_to_cstring(path,context.temp_allocator)))
	return image
}

main :: proc() {
	if len(os.args)>1 {Output=os.args[1]}
	compensated:=len(os.args)>2 && os.args[2]=="compensated"
	assert(os.make_directory(Output)==nil || os.is_dir(Output))
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(800,600,"Rune SSAO FOV regression"); defer rl.CloseWindow()
	ctx,ready:=bridge.init(".",800,600); assert(ready); defer bridge.shutdown(&ctx)
	manager:=assets.init("."); defer assets.shutdown(&manager)
	registry:=ecs.init_registry(); defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	world:=ecs.init(); defer ecs.destroy(&world)
	camera_entity:=ecs.create_entity(&world)
	camera:=rl.Camera3D{position={4,4,-9},target={0,1,1},up={0,1,0},fovy=70}
	assert(ecs.add(&world,&registry,camera_entity,ecs.Transform{position=camera.position,scale={1,1,1}}))
	assert(ecs.add(&world,&registry,camera_entity,ecs.Camera3D{target=camera.target,up=camera.up,fovy=70,active=true}))
	post:=ecs.default_post_processing()
	post.anti_aliasing=.disabled
	post.ssao={enabled=true,sample_count=64,intensity=0.8,power=1,max_radius=0.2,radius=2,bias=0.03}
	assert(ecs.add(&world,&registry,camera_entity,post))
	ambient:=ecs.create_entity(&world)
	assert(ecs.add(&world,&registry,ambient,ecs.AmbientLight{color={255,255,255,255},intensity=0.6}))
	entities: [2]ecs.Entity
	for shape,index in ([]ecs.Transform{
		{position={0,-0.1,0},scale={24,0.2,24}},
		{position={0,4,2.1},scale={24,8,0.2}},
	}) {
		entity:=ecs.create_entity(&world)
		entities[index]=entity
		assert(ecs.add(&world,&registry,entity,shape))
		assert(ecs.add(&world,&registry,entity,ecs.MeshRenderer{primitive="cube",color={180,180,180,255},shadows=false}))
	}
	results:=make([dynamic]Result); defer delete(results)
	for scene in ([]string{"near-corner","far-corner","flat-plane","sloped-plane"}) {
		plane_only:=scene=="flat-plane" || scene=="sloped-plane"
		ecs.set_enabled(&world,entities[1],!plane_only)
		camera.position={0,1.2,-0.5}; camera.target={0,1,2}
		if scene=="far-corner" {camera.position={0,4,-9}; camera.target={0,1,1}}
		if scene=="sloped-plane" {camera.position={0,2,-3}; camera.target={0,0,1}}
		world.transforms[camera_entity]=ecs.Transform{position=camera.position,scale={1,1,1}}
		angle:f32=25 if scene=="sloped-plane" else 0
		sine,cosine:=math.sin(angle*math.PI/180),math.cos(angle*math.PI/180)
		world.transforms[entities[0]]=ecs.Transform{position={sine*0.1,-cosine*0.1,0},rotation={0,0,angle},scale={24,0.2,24}}
		for size in ([][2]i32{{800,600},{960,540},{600,800}}) {
		rl.SetWindowSize(size[0],size[1])
		for fov,index in ([4]f32{70,72,74,70}) {
			camera.fovy=fov
			assert(ecs.set_camera_3d(&world,camera_entity,ecs.Camera3D{target=camera.target,up=camera.up,fovy=fov,active=true}))
			reference_fovy:f32=70 if compensated else 0
			result:=Result{label=fmt.tprintf("%s-%dx%d-fov%.0f-%d",scene,size[0],size[1],fov,index),scene=scene,width=size[0],height=size[1],fovy=fov,authored_max_radius=post.ssao.max_radius,ssao_reference_fovy=reference_fovy,compensated=compensated}
			post.ssao.enabled=true; assert(ecs.set(&world,camera_entity,post))
			result.on_path=fmt.tprintf("%s/%s-on.png",Output,result.label)
			on:=render(&ctx,&world,&manager,result.on_path,reference_fovy)
			result.ssao_enabled=r3d.GetEnvironment().ssao.enabled
			assert(result.ssao_enabled && !r3d.GetEnvironment().ssil.enabled && !r3d.GetEnvironment().ssgi.enabled)
			profile,profile_found:=ecs.get(&world,camera_entity,ecs.PostProcessing)
			assert(profile_found && profile.ssao.max_radius==0.2,"draw-scoped FOV compensation must preserve the ECS profile")
			post.ssao.enabled=false; assert(ecs.set(&world,camera_entity,post))
			result.off_path=fmt.tprintf("%s/%s-off.png",Output,result.label)
			off:=render(&ctx,&world,&manager,result.off_path,reference_fovy)
			assert(!r3d.GetEnvironment().ssao.enabled)
			assert(r3d.GetEnvironment().ssao.maxRadius==0.2)
			for x in 0..<13 {
				along:=-0.6+f32(x)*0.1
				value:=sample(on,off,{along*cosine-sine*0.001,along*sine+cosine*0.001,1.75},camera,size[0],size[1])
				append(&result.corner,value); result.corner_drop+=value.drop/13
			}
			for x in 0..<9 {for z in 0..<7 {
				along:=-0.4+f32(x)*0.1
				depth:=1.3+f32(z)*0.1
				if scene=="far-corner" {depth=-5+f32(z)*0.5}
				value:=sample(on,off,{along*cosine-sine*0.001,along*sine+cosine*0.001,depth},camera,size[0],size[1])
				append(&result.floor,value); result.floor_drop+=value.drop/63
				result.max_floor_drop=max(result.max_floor_drop,value.drop)
			}}
			if !plane_only {for x in 0..<13 {for y in 0..<5 {
				height:=1.6+f32(y)*0.1
				if scene=="far-corner" {height=3+f32(y)*0.3}
				value:=sample(on,off,{-0.6+f32(x)*0.1,height,1.999},camera,size[0],size[1])
				append(&result.wall,value); result.wall_drop+=value.drop/65
				result.max_wall_drop=max(result.max_wall_drop,value.drop)
			}}}
			rl.UnloadImage(on); rl.UnloadImage(off)
			fmt.printf("%s corner=%.3f floor=%.3f (max %.3f) wall=%.3f (max %.3f)\n",result.label,result.corner_drop,result.floor_drop,result.max_floor_drop,result.wall_drop,result.max_wall_drop)
			append(&results,result)
		}
	}
	}
	bytes,err:=json.marshal(results[:],{pretty=true},allocator=context.temp_allocator); assert(err==nil)
	assert(os.write_entire_file(fmt.tprintf("%s/results.json",Output),bytes)==nil)
	sweeps:=make([dynamic]Sweep); defer delete(sweeps)
	for i:=0; i<len(results); i+=4 {
		base,sprint,returned:=results[i],results[i+2],results[i+3]
		sweep:=Sweep{scene=base.scene,width=base.width,height=base.height,compensated=compensated,
			base_floor_drop=base.floor_drop,sprint_floor_drop=sprint.floor_drop,
			base_corner_drop=base.corner_drop,sprint_corner_drop=sprint.corner_drop}
		for j in 1..<3 {
			sweep.max_floor_shift=max(sweep.max_floor_shift,abs(results[i+j].floor_drop-base.floor_drop))
			sweep.max_corner_shift=max(sweep.max_corner_shift,abs(results[i+j].corner_drop-base.corner_drop))
		}
		if base.floor_drop>0 {sweep.relative_floor_shift=sweep.max_floor_shift/base.floor_drop}
		first_image:=rl.LoadImage(strings.clone_to_cstring(base.on_path,context.temp_allocator))
		return_image:=rl.LoadImage(strings.clone_to_cstring(returned.on_path,context.temp_allocator))
		first_pixels:=rl.LoadImageColors(first_image)
		return_pixels:=rl.LoadImageColors(return_image)
		for pixel in 0..<int(base.width*base.height) {
			if first_pixels[pixel]!=return_pixels[pixel] {sweep.return_changed_pixels+=1}
		}
		rl.UnloadImageColors(first_pixels); rl.UnloadImageColors(return_pixels)
		rl.UnloadImage(first_image); rl.UnloadImage(return_image)
		append(&sweeps,sweep)
		assert(sweep.return_changed_pixels==0,"returning to FOV70 must exactly restore deterministic rendering")
		if compensated && base.scene=="near-corner" {
			assert(sweep.max_floor_shift<0.12 && sweep.relative_floor_shift<0.03,"compensated sprint FOV must retain fixed-world regional AO contrast")
			assert(sweep.max_corner_shift<0.4,"contact-line AO must remain stable within raster sampling tolerance")
		}
		if !compensated && base.scene=="near-corner" {
			assert(sweep.relative_floor_shift>0.05,"baseline scene must expose the capped-radius FOV strength pulse")
		}
	}
	bytes,err=json.marshal(sweeps[:],{pretty=true},allocator=context.temp_allocator); assert(err==nil)
	assert(os.write_entire_file(fmt.tprintf("%s/sweeps.json",Output),bytes)==nil)
	for result in results {
		if result.scene=="near-corner" || result.scene=="far-corner" {assert(result.corner_drop>3,"AO must still provide genuine floor-wall contact contrast")}
		if result.scene=="flat-plane" || result.scene=="sloped-plane" {
			assert(result.max_floor_drop<0.25 && result.corner_drop<0.25,"unoccluded planes must not develop false AO during FOV changes")
		}
		assert(!math.is_nan(result.floor_drop) && !math.is_nan(result.wall_drop))
		delete(result.corner); delete(result.floor); delete(result.wall)
	}
}
