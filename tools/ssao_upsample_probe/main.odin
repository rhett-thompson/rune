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

Sample :: struct {
	point:[3]f32,
	pixel:[2]int,
	depth:f32,
	lateral:f32,
	on,off,drop,raw_ao:f64,
}
Result :: struct {
	label,scene:string,
	width,height:i32,
	fovy:f32,
	mean_drop,max_drop,mean_raw,max_raw:f64,
	max_image_difference,max_raw_occlusion:int,
	samples:[dynamic]Sample,
}

Sweep :: struct {
	scene:string,
	width,height:i32,
	samples_per_frame:int,
	max_false_shading,max_raw_occlusion,max_world_fov_shift:f64,
	return_changed_pixels:[3]int,
}

luma :: proc(c:rl.Color)->f64 {return .2126*f64(c.r)+.7152*f64(c.g)+.0722*f64(c.b)}

pixel_mean :: proc(im:rl.Image,x,y:int)->f64 {
	value:f64
	for dy in -1..=1 {for dx in -1..=1 {value+=luma(rl.GetImageColor(im,i32(x+dx),i32(y+dy)))}}
	return value/9
}

render :: proc(ctx:^bridge.Context,w:^ecs.World,manager:^assets.Asset_Manager,path:string,reference:f32,mode:r3d.OutputMode)->rl.Image {
	r3d.SetOutputMode(mode)
	for _ in 0..<4 {
		rl.BeginDrawing();rl.ClearBackground({15,19,24,255})
		assert(bridge.draw_scene_ex(ctx,w,manager,{background_color={15,19,24,255},ssao_reference_fovy=reference}))
		rl.EndDrawing()
	}
	im:=rl.LoadImageFromScreen()
	assert(rl.ExportImage(im,strings.clone_to_cstring(path,context.temp_allocator)))
	return im
}

main :: proc() {
	out:="build/ssao-upsample-probe"
	if len(os.args)>1 {out=os.args[1]}
	assert(os.make_directory(out)==nil || os.is_dir(out))
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(960,540,"SSAO grazing-plane regression");defer rl.CloseWindow()
	ctx,ready:=bridge.init(".",960,540);assert(ready);defer bridge.shutdown(&ctx)
	manager:=assets.init(".");defer assets.shutdown(&manager)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
	w:=ecs.init();defer ecs.destroy(&w)
	ce:=ecs.create_entity(&w)
	camera:=rl.Camera3D{position={0,1.7,0},target={0,1.7,100},up={0,1,0},fovy=70}
	assert(ecs.add(&w,&r,ce,ecs.Transform{position=camera.position,scale={1,1,1}}))
	assert(ecs.add(&w,&r,ce,ecs.Camera3D{target=camera.target,up=camera.up,fovy=70,active=true}))
	post:=ecs.default_post_processing();post.anti_aliasing=.disabled
	post.ssao={enabled=true,sample_count=64,intensity=.8,power=1,max_radius=.2,radius=2,bias=.03}
	assert(ecs.add(&w,&r,ce,post))
	ambient:=ecs.create_entity(&w);assert(ecs.add(&w,&r,ambient,ecs.AmbientLight{color={255,255,255,255},intensity=.6}))
	plane:=ecs.create_entity(&w)
	assert(ecs.add(&w,&r,plane,ecs.Transform{position={0,-.1,0},scale={2000,.2,2000}}))
	assert(ecs.add(&w,&r,plane,ecs.MeshRenderer{primitive="cube",color={180,180,180,255},shadows=false}))
	results:=make([dynamic]Result);defer delete(results)
	for scene in ([]string{"flat-grazing-plane","sloped-grazing-plane"}) {
		angle:f32=4 if scene=="sloped-grazing-plane" else 0
		sine,cosine:=math.sin(angle*math.PI/180),math.cos(angle*math.PI/180)
		w.transforms[plane]=ecs.Transform{position={.1*sine,-.1*cosine,0},rotation={0,0,angle},scale={2000,.2,2000}}
		for size in ([][2]i32{{960,540},{959,539},{541,769}}) {
			rl.SetWindowSize(size[0],size[1])
			for fov,index in ([4]f32{70,72,74,70}) {
				camera.fovy=fov;assert(ecs.set_camera_3d(&w,ce,ecs.Camera3D{target=camera.target,up=camera.up,fovy=fov,active=true}))
				label:=fmt.tprintf("%s-%dx%d-fov%.0f-%d",scene,size[0],size[1],fov,index)
				post.ssao.enabled=true;assert(ecs.set(&w,ce,post))
				on:=render(&ctx,&w,&manager,fmt.tprintf("%s/%s-on.png",out,label),70,.SCENE)
				raw:=render(&ctx,&w,&manager,fmt.tprintf("%s/%s-raw.png",out,label),70,.SSAO)
				post.ssao.enabled=false;assert(ecs.set(&w,ce,post))
				off:=render(&ctx,&w,&manager,fmt.tprintf("%s/%s-off.png",out,label),70,.SCENE)
				result:=Result{label=label,scene=scene,width=size[0],height=size[1],fovy=fov}
				assert(on.width==size[0] && on.height==size[1] && raw.width==size[0] && raw.height==size[1] && off.width==size[0] && off.height==size[1],"render buffers must follow each viewport size")
				on_pixels,off_pixels,raw_pixels:=rl.LoadImageColors(on),rl.LoadImageColors(off),rl.LoadImageColors(raw)
				for pixel in 0..<int(size[0]*size[1]) {
					a,b,c:=on_pixels[pixel],off_pixels[pixel],raw_pixels[pixel]
					result.max_image_difference=max(result.max_image_difference,abs(int(a.r)-int(b.r)),abs(int(a.g)-int(b.g)),abs(int(a.b)-int(b.b)))
					result.max_raw_occlusion=max(result.max_raw_occlusion,255-int(c.r),255-int(c.g),255-int(c.b))
				}
				rl.UnloadImageColors(on_pixels);rl.UnloadImageColors(off_pixels);rl.UnloadImageColors(raw_pixels)
				for depth in ([]f32{8,16,32,48,64,72,80,88,96,104,112,120,128,136,144,152,160,168,176,184,192,200,208,216,224,232,240,248,256}) {for lateral in ([]f32{-.85,-.6,-.3,0,.3,.6,.85}) {
					// Baseline-lens projected horizontal fractions keep the same
					// world points inside every FOV while covering viewport edges.
					along:=lateral*depth*f32(math.tan(35*math.PI/180))*f32(size[0])/f32(size[1])
					point:=[3]f32{along*cosine-.001*sine,along*sine+.001*cosine,depth}
					pixel:=rl.GetWorldToScreenEx(point,camera,size[0],size[1]);x,y:=int(pixel.x),int(pixel.y)
					if x<2 || y<2 || x>=int(size[0])-2 || y>=int(size[1])-2 {continue}
					value:=Sample{point=point,pixel={x,y},depth=depth,lateral=lateral,on=pixel_mean(on,x,y),off=pixel_mean(off,x,y),raw_ao=255-pixel_mean(raw,x,y)}
					value.drop=value.off-value.on;append(&result.samples,value)
					result.mean_drop+=value.drop;result.max_drop=max(result.max_drop,value.drop)
					result.mean_raw+=value.raw_ao;result.max_raw=max(result.max_raw,value.raw_ao)
				}}
				result.mean_drop/=f64(len(result.samples));result.mean_raw/=f64(len(result.samples))
				fmt.printf("%s mean drop %.4f max %.4f raw mean %.4f max %.4f\n",label,result.mean_drop,result.max_drop,result.mean_raw,result.max_raw)
				append(&results,result);rl.UnloadImage(on);rl.UnloadImage(off);rl.UnloadImage(raw)
			}
		}
	}
	data,err:=json.marshal(results[:],{pretty=true},allocator=context.temp_allocator);assert(err==nil)
	assert(os.write_entire_file(fmt.tprintf("%s/results.json",out),data)==nil)
	sweeps:=make([dynamic]Sweep);defer delete(sweeps)
	for i:=0;i<len(results);i+=4 {
		base,returned:=results[i],results[i+3]
		sweep:=Sweep{scene=base.scene,width=base.width,height=base.height,samples_per_frame=len(base.samples)}
		for j in 0..<4 {
			result:=results[i+j]
			assert(len(result.samples)==203,"every viewport must retain all 29 depth and seven lateral samples")
			sweep.max_false_shading=max(sweep.max_false_shading,result.max_drop)
			sweep.max_raw_occlusion=max(sweep.max_raw_occlusion,result.max_raw)
			for value,k in result.samples {sweep.max_world_fov_shift=max(sweep.max_world_fov_shift,abs(value.drop-base.samples[k].drop))}
		}
		for mode,index in ([]string{"on","off","raw"}) {
			first:=rl.LoadImage(strings.clone_to_cstring(fmt.tprintf("%s/%s-%s.png",out,base.label,mode),context.temp_allocator))
			last:=rl.LoadImage(strings.clone_to_cstring(fmt.tprintf("%s/%s-%s.png",out,returned.label,mode),context.temp_allocator))
			first_pixels,last_pixels:=rl.LoadImageColors(first),rl.LoadImageColors(last)
			for pixel in 0..<int(base.width*base.height) {if first_pixels[pixel]!=last_pixels[pixel] {sweep.return_changed_pixels[index]+=1}}
			rl.UnloadImageColors(first_pixels);rl.UnloadImageColors(last_pixels);rl.UnloadImage(first);rl.UnloadImage(last)
		}
		append(&sweeps,sweep)
	}
	data,err=json.marshal(sweeps[:],{pretty=true},allocator=context.temp_allocator);assert(err==nil)
	assert(os.write_entire_file(fmt.tprintf("%s/sweeps.json",out),data)==nil)
	// Isolated planes have no occluders. Their raw white SSAO must remain white
	// through bilateral upsampling, including grazing depths and odd viewports.
	for result in results {
		assert(result.max_image_difference<=1 && result.max_raw_occlusion<=1,"unoccluded raw AO and final lighting must stay constant across the complete image")
		assert(result.max_drop<.25 && result.max_raw<.25,"unoccluded world samples must not develop false AO")
	}
	for sweep in sweeps {
		assert(sweep.max_world_fov_shift<.25,"FOV animation must not pulse unoccluded ambient shading at fixed world positions")
		assert(sweep.return_changed_pixels==[3]int{},"returning to FOV70 must restore every on/off/raw pixel exactly")
	}
	for result in results {delete(result.samples)}
}
