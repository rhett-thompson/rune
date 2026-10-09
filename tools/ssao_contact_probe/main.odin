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

Profile :: struct {
	label:string,
	values:[dynamic]f64,
	native_values:[dynamic]f64,
	peak,area:f64,
	widths:[7]f64,
	native_peak:f64,
	native_widths:[7]f64,
}

Frame :: struct {
	label,scene,effect:string,
	width,height:i32,
	fovy,sampling_fovy:f32,
	profiles:[6]Profile,
	on_path,off_path:string,
	native_path:string,
	native_changed_pixels,max_native_rgb_difference:int,
}

Sweep :: struct {
	scene,effect:string,
	width,height:i32,
	stable:bool,
	frames,samples_per_profile:int,
	min_peak,max_peak,max_world_delta,max_width_shift,max_relative_width_shift,max_area_shift:f64,
	worst_width_profile,worst_width_frame,worst_width_level:int,
	max_width_shift_pixels:f64,
	max_dark_width_shift_pixels,max_dark_width_shift:f64,
	max_native_world_delta,max_native_width_shift:f64,
	native_changed_pixels,max_native_rgb_difference:int,
	native_contact_stable,stable_criteria_passed:bool,
	return_changed_pixels:[2]int,
}

Steps :: 240
Distance_Start :: 0.005
Distance_Step :: 0.005
Contact_Z :: 2.0
Sampling_Fov :: 75.8
Sampling_Enabled:bool

presented_pixel :: proc(point:[3]f32,camera:rl.Camera3D,width,height:i32)->[2]f32 {
	if !Sampling_Enabled {
		p:=rl.GetWorldToScreenEx(point,camera,width,height)
		return {p.x,p.y}
	}
	magnification:=math.tan(f64(Sampling_Fov)*math.PI/360)/math.tan(f64(camera.fovy)*math.PI/360)
	viewport_width,viewport_height:=f32(f64(width)*magnification),f32(f64(height)*magnification)
	dst_width,dst_height:=i32(viewport_width+.5),i32(viewport_height+.5)
	dst_x,dst_y:=-((dst_width-width)/2),-((dst_height-height)/2)
	projection:=camera;projection.fovy=Sampling_Fov
	p:=rl.GetWorldToScreenEx(point,projection,width,height)
	// R3D projects using the floating viewport aspect, then rounds the actual
	// presentation extent and origin. Register against those actual geometry
	// rays rather than treating a half-pixel crop offset as changing occlusion.
	aspect_correction:=(f32(width)/f32(height))/(viewport_width/viewport_height)
	p.x=f32(width)*.5+(p.x-f32(width)*.5)*aspect_correction
	return {f32(dst_x)+p.x*f32(dst_width)/f32(width),f32(dst_y)+p.y*f32(dst_height)/f32(height)}
}

luma :: proc(c:rl.Color)->f64 {return .2126*f64(c.r)+.7152*f64(c.g)+.0722*f64(c.b)}

// Bilinear reconstruction samples one fixed world point. A screen-pixel box
// average would itself widen in world space as the visible lens changes.
sample :: proc(pixels:[^]rl.Color,point:[3]f32,camera:rl.Camera3D,width,height:i32,native:bool=false)->f64 {
	p:=presented_pixel(point,camera,width,height)
	if native {
		projection:=camera
		if Sampling_Enabled {projection.fovy=Sampling_Fov}
		q:=rl.GetWorldToScreenEx(point,projection,width,height)
		p={q.x,q.y}
	}
	x,y:=int(math.floor(p.x-.5)),int(math.floor(p.y-.5))
	assert(x>=0 && y>=0 && x<int(width)-1 && y<int(height)-1,"profile must remain on its receiving surface in every view")
	fx,fy:=f64(p.x-.5-f32(x)),f64(p.y-.5-f32(y))
	a,b:=luma(pixels[y*int(width)+x]),luma(pixels[y*int(width)+x+1])
	c,d:=luma(pixels[(y+1)*int(width)+x]),luma(pixels[(y+1)*int(width)+x+1])
	return (a*(1-fx)+b*fx)*(1-fy)+(c*(1-fx)+d*fx)*fy
}

render :: proc(ctx:^bridge.Context,w:^ecs.World,manager:^assets.Asset_Manager,path:string,sampling_fovy:f32,mode:r3d.OutputMode=.SCENE)->rl.Image {
	r3d.SetOutputMode(mode)
	upscale:=r3d.GetUpscaleMode()
	for _ in 0..<2 {
		rl.BeginDrawing();rl.ClearBackground({15,19,24,255})
		assert(bridge.draw_scene_ex(ctx,w,manager,{background_color={15,19,24,255},ssao_reference_fovy=70,sampling_fovy=sampling_fovy}))
		assert(r3d.GetUpscaleMode()==upscale,"sampling crop must restore the authored presentation filter after each draw")
		rl.EndDrawing()
	}
	result:=rl.LoadImageFromScreen()
	if path!="" {assert(rl.ExportImage(result,strings.clone_to_cstring(path,context.temp_allocator)))}
	return result
}

contour :: proc(values:[]f64,threshold:f64)->f64 {
	if threshold<=0 {return 0}
	peak:f64
	peak_index:int
	for value,index in values {if value>peak {peak,peak_index=value,index}}
	if peak<threshold {return 0}
	// Follow the contact band from its peak. Ignore one- or two-sample holes
	// caused by reconstruction, but stop before separate distant noise islands.
	for index:=peak_index+1;index<len(values)-2;index+=1 {
		if values[index]<threshold && values[index+1]<threshold && values[index+2]<threshold {
			previous:=values[index-1]
			fraction:=clamp((previous-threshold)/max(previous-values[index],1e-12),0,1)
			return Distance_Start+Distance_Step*(f64(index-1)+fraction)
		}
	}
	return Distance_Start+Distance_Step*f64(len(values)-1)
}

profile_point :: proc(edge_x:f32,surface,index:int,along:f32=0)->[3]f32 {
	d:=f32(Distance_Start+Distance_Step*f64(index))
	if surface==0 {return {edge_x+along,.001,Contact_Z-d}}
	return {edge_x+along,d,Contact_Z-.001}
}

world_per_pixel :: proc(edge_x:f32,surface:int,distance:f64,camera:rl.Camera3D,width,height:i32)->f64 {
	a,b:[3]f32
	if surface==0 {a={edge_x,.001,Contact_Z-f32(distance-.005)};b={edge_x,.001,Contact_Z-f32(distance+.005)}}
	else {a={edge_x,f32(distance-.005),Contact_Z-.001};b={edge_x,f32(distance+.005),Contact_Z-.001}}
	x,y:=presented_pixel(a,camera,width,height),presented_pixel(b,camera,width,height)
	dx,dy:=f64(x.x-y.x),f64(x.y-y.y)
	return .01/max(math.sqrt(dx*dx+dy*dy),1e-9)
}

main :: proc() {
	out:="build/ssao-contact-probe"
	if len(os.args)>1 {out=os.args[1]}
	stable:=len(os.args)>2 && os.args[2]=="stable"
	if len(os.args)>2 {assert(os.args[2]=="stable" || os.args[2]=="baseline","mode must be baseline or stable")}
	Sampling_Enabled=stable
	quick:=len(os.args)>3 && os.args[3]=="quick"
	assert(os.make_directory(out)==nil || os.is_dir(out))
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(960,540,"Rune SSAO contact contour regression");defer rl.CloseWindow()
	ctx,ready:=bridge.init(".",960,540);assert(ready);defer bridge.shutdown(&ctx)
	manager:=assets.init(".");defer assets.shutdown(&manager)
	registry:=ecs.init_registry();defer ecs.destroy_registry(&registry);assert(ecs.register_builtin_components(&registry))
	world:=ecs.init();defer ecs.destroy(&world)
	ce:=ecs.create_entity(&world)
	camera:=rl.Camera3D{position={0,1.7,-1},target={0,.9,2},up={0,1,0},fovy=70}
	assert(ecs.add(&world,&registry,ce,ecs.Transform{position=camera.position,scale={1,1,1}}))
	assert(ecs.add(&world,&registry,ce,ecs.Camera3D{target=camera.target,up=camera.up,fovy=70,active=true}))
	post:=ecs.default_post_processing();post.anti_aliasing=.disabled
	post.ssao={enabled=true,sample_count=64,intensity=.8,power=1,max_radius=.2,radius=2,bias=.03}
	post.ssgi={enabled=false,slice_count=4,edge_fade=.15,distance_falloff=.25,normal_rejection=1,intensity=1,denoise_steps=4}
	assert(ecs.add(&world,&registry,ce,post))
	ambient:=ecs.create_entity(&world)
	assert(ecs.add(&world,&registry,ambient,ecs.AmbientLight{color={255,255,255,255},intensity=.6}))
	sun:=ecs.create_entity(&world)
	assert(ecs.add(&world,&registry,sun,ecs.DirectionalLight{direction={.3,-.7,.4},color={255,255,255,255},intensity=.6,specular=0,range=100,shadows=false}))
	floor:=ecs.create_entity(&world)
	assert(ecs.add(&world,&registry,floor,ecs.Transform{position={0,-.1,0},scale={24,.2,24}}))
	assert(ecs.add(&world,&registry,floor,ecs.MeshRenderer{primitive="cube",color={180,180,180,255},shadows=false}))
	walls:[3]ecs.Entity
	for index in 0..<3 {
		walls[index]=ecs.create_entity(&world)
		assert(ecs.add(&world,&registry,walls[index],ecs.Transform{scale={1,1,1}}))
		assert(ecs.add(&world,&registry,walls[index],ecs.MeshRenderer{primitive="cube",color={180,180,180,255},shadows=false}))
	}
	frames:=make([dynamic]Frame);defer delete(frames)
	sweeps:=make([dynamic]Sweep);defer delete(sweeps)
	for scene in ([]string{"wall","pillars"}) {for size in ([][2]i32{{960,540},{959,539},{541,769}}) {
		if quick && (scene!="wall" || size!=[2]i32{960,540}) {continue}
		rl.SetWindowSize(size[0],size[1])
		// Fixed physical locations corresponding to +/-55% baseline horizontal
		// NDC. They stay on-screen for every FOV and portrait aspect ratio.
		forward:=camera.target-camera.position
		forward/=math.sqrt(forward[0]*forward[0]+forward[1]*forward[1]+forward[2]*forward[2])
		contact:=[3]f32{0,0,Contact_Z}
		view_depth:=f32(0)
		for axis in 0..<3 {view_depth+=(contact[axis]-camera.position[axis])*forward[axis]}
		edge_extent:=.55*view_depth*f32(math.tan(35*math.PI/180))*f32(size[0])/f32(size[1])
		edges:=[3]f32{-edge_extent,0,edge_extent}
		for index in 0..<3 {
			ecs.set_enabled(&world,walls[index],scene=="pillars" || index==1)
			shape:=ecs.Transform{position={edges[index],.8,Contact_Z+.3},scale={.65,1.6,.6}}
			if scene=="wall" {shape=ecs.Transform{position={0,4,Contact_Z+.1},scale={24,8,.2}}}
			assert(ecs.set_transform(&world,walls[index],shape))
		}
		for effect in ([]string{"ao","gi","combined"}) {
			ecs.set_enabled(&world,sun,effect!="ao")
			assert(ecs.set(&world,ambient,ecs.AmbientLight{color={255,255,255,255},intensity=.6 if effect=="ao" else .24}))
			post.tonemap={mode=.linear,exposure=1,white=1}
			post.color={brightness=1,contrast=1,saturation=1}
			if effect!="ao" {post.tonemap={mode=.aces,exposure=.65,white=1};post.color={brightness=1,contrast=1.05,saturation=1.92}}
			first:=len(frames)
			first_images:[2]rl.Image
			first_source:rl.Image
			for step in 0..<21 {
				camera.fovy=70+.4*f32(step if step<=10 else 20-step)
				assert(ecs.set_camera_3d(&world,ce,ecs.Camera3D{target=camera.target,up=camera.up,fovy=camera.fovy,active=true}))
				label:=fmt.tprintf("%s-%s-%dx%d-step%02d-fov%.1f",scene,effect,size[0],size[1],step,camera.fovy)
				frame:=Frame{label=label,scene=scene,effect=effect,width=size[0],height=size[1],fovy=camera.fovy,sampling_fovy=Sampling_Fov if stable else 0}
				if step==0 || step==10 || step==20 {
					frame.on_path=fmt.tprintf("%s/%s-on.png",out,label)
					frame.off_path=fmt.tprintf("%s/%s-off.png",out,label)
					frame.native_path=fmt.tprintf("%s/%s-native.png",out,label)
				}
				post.ssao.enabled=effect!="gi";post.ssgi.enabled=effect!="ao";assert(ecs.set(&world,ce,post))
				on:=render(&ctx,&world,&manager,frame.on_path,frame.sampling_fovy)
				source:=render(&ctx,&world,&manager,frame.native_path,frame.sampling_fovy,.SSGI if effect=="gi" else .SSAO)
				post.ssao.enabled=false;post.ssgi.enabled=effect=="combined";assert(ecs.set(&world,ce,post))
				off:=render(&ctx,&world,&manager,frame.off_path,frame.sampling_fovy)
				on_pixels,off_pixels:=rl.LoadImageColors(on),rl.LoadImageColors(off)
				source_pixels:=rl.LoadImageColors(source)
				if step!=0 {
					base_pixels:=rl.LoadImageColors(first_source)
					for pixel in 0..<int(size[0]*size[1]) {
						a,b:=source_pixels[pixel],base_pixels[pixel]
						if a!=b {frame.native_changed_pixels+=1}
						frame.max_native_rgb_difference=max(frame.max_native_rgb_difference,abs(int(a.r)-int(b.r)),abs(int(a.g)-int(b.g)),abs(int(a.b)-int(b.b)))
					}
					rl.UnloadImageColors(base_pixels)
				}
				for edge,index in edges {for surface in 0..<2 {
					profile:=&frame.profiles[index*2+surface]
					profile.label=fmt.tprintf("edge%d-%s",index,"floor" if surface==0 else "wall")
					profile.values=make([dynamic]f64)
					profile.native_values=make([dynamic]f64)
					for point_index in 0..=Steps {
						value,native_value:f64
						for along in ([]f32{-.08,-.04,0,.04,.08}) {
							point:=profile_point(edge,surface,point_index,along)
							a,b:=sample(on_pixels,point,camera,size[0],size[1]),sample(off_pixels,point,camera,size[0],size[1])
							value+=(b-a)/max(b,1)/5 if effect!="gi" else (a-b)/max(b,1)/5
							c:=sample(source_pixels,point,camera,size[0],size[1],native=true)/255
							native_value+=(1-c)/5 if effect!="gi" else c/5
						}
						append(&profile.values,value);profile.peak=max(profile.peak,value);profile.area+=max(value,0)*Distance_Step
						append(&profile.native_values,native_value);profile.native_peak=max(profile.native_peak,native_value)
					}
					base_peak:=profile.peak if step==0 else frames[first].profiles[index*2+surface].peak
					for level,level_index in ([7]f64{.01,.02,.04,.08,base_peak*.25,base_peak*.5,base_peak*.75}) {
						profile.widths[level_index]=contour(profile.values[:],level)
					}
					native_peak:=profile.native_peak if step==0 else frames[first].profiles[index*2+surface].native_peak
					for level,level_index in ([7]f64{.01,.02,.04,.08,native_peak*.25,native_peak*.5,native_peak*.75}) {profile.native_widths[level_index]=contour(profile.native_values[:],level)}
				}}
				rl.UnloadImageColors(on_pixels);rl.UnloadImageColors(off_pixels)
				rl.UnloadImageColors(source_pixels)
				append(&frames,frame)
				if step==0 {first_images={on,off};first_source=source}
				else {
					if step==20 {
						for im,index in ([2]rl.Image{on,off}) {
							a,b:=rl.LoadImageColors(first_images[index]),rl.LoadImageColors(im)
							changed:=0
							for pixel in 0..<int(size[0]*size[1]) {if a[pixel]!=b[pixel] {changed+=1}}
							assert(changed==0,"returning to the base lens must restore the exact scene image")
							rl.UnloadImageColors(a);rl.UnloadImageColors(b)
						}
					}
					rl.UnloadImage(on);rl.UnloadImage(off)
					rl.UnloadImage(source)
				}
			}
			rl.UnloadImage(first_images[0]);rl.UnloadImage(first_images[1])
			rl.UnloadImage(first_source)
			sweep:=Sweep{scene=scene,effect=effect,width=size[0],height=size[1],stable=stable,frames=21,samples_per_profile=Steps+1,min_peak=1e30}
			base:=frames[first]
			for frame,frame_index in frames[first:first+21] {
				sweep.native_changed_pixels=max(sweep.native_changed_pixels,frame.native_changed_pixels)
				sweep.max_native_rgb_difference=max(sweep.max_native_rgb_difference,frame.max_native_rgb_difference)
				for profile,index in frame.profiles {
				sweep.min_peak=min(sweep.min_peak,profile.peak);sweep.max_peak=max(sweep.max_peak,profile.peak)
				sweep.max_area_shift=max(sweep.max_area_shift,abs(profile.area-base.profiles[index].area))
				for value,point_index in profile.values {sweep.max_world_delta=max(sweep.max_world_delta,abs(value-base.profiles[index].values[point_index]))}
				for value,point_index in profile.native_values {sweep.max_native_world_delta=max(sweep.max_native_world_delta,abs(value-base.profiles[index].native_values[point_index]))}
				for width,level_index in profile.native_widths {sweep.max_native_width_shift=max(sweep.max_native_width_shift,abs(width-base.profiles[index].native_widths[level_index]))}
				for width,level_index in profile.widths {
					base_width:=base.profiles[index].widths[level_index]
					if base_width==0 || width==0 || base_width>=1.2 || width>=1.2 {continue}
					shift:=abs(width-base_width)
					if shift>sweep.max_width_shift {sweep.max_width_shift=shift;sweep.worst_width_frame=frame_index;sweep.worst_width_profile=index;sweep.worst_width_level=level_index}
					sweep.max_relative_width_shift=max(sweep.max_relative_width_shift,shift/base_width)
					pixels:=shift/world_per_pixel(edges[index/2],index%2,base_width,camera,size[0],size[1])
					sweep.max_width_shift_pixels=max(sweep.max_width_shift_pixels,pixels)
					if level_index==2 || level_index==3 {
						sweep.max_dark_width_shift_pixels=max(sweep.max_dark_width_shift_pixels,pixels)
						sweep.max_dark_width_shift=max(sweep.max_dark_width_shift,shift)
					}
				}
			}}
			sweep.native_contact_stable=sweep.max_native_world_delta<=1.0/255 && sweep.max_native_width_shift<=Distance_Step
			sweep.stable_criteria_passed=sweep.native_contact_stable && sweep.max_native_rgb_difference<=1
			if effect=="ao" {sweep.stable_criteria_passed=sweep.stable_criteria_passed && sweep.max_dark_width_shift_pixels<=2}
			if effect=="combined" {sweep.stable_criteria_passed=sweep.stable_criteria_passed && sweep.max_dark_width_shift_pixels<=3}
			assert(sweep.max_peak>.01,"the fixture must retain measurable contact shading or indirect lighting")
			if effect!="gi" {assert(sweep.min_peak>.04,"sampling stabilization must preserve dark contact bands")}
			if stable {assert(sweep.stable_criteria_passed,"fixed sampling must retain native contact profiles and dark contours within presentation reconstruction tolerance")}
			else {assert(!sweep.native_contact_stable,"baseline must expose actual fixed-world contact footprint variation")}
			append(&sweeps,sweep)
			fmt.printf("%s/%s %dx%d stable=%v peak %.4f..%.4f world_delta %.5f contour %.5fm (%.2fpx,%.2f%%) dark %.5fm %.2fpx native_pixels %d (rgb %d) native_delta %.6f native_contour %.6fm\n",scene,effect,size[0],size[1],stable,sweep.min_peak,sweep.max_peak,sweep.max_world_delta,sweep.max_width_shift,sweep.max_width_shift_pixels,sweep.max_relative_width_shift*100,sweep.max_dark_width_shift,sweep.max_dark_width_shift_pixels,sweep.native_changed_pixels,sweep.max_native_rgb_difference,sweep.max_native_world_delta,sweep.max_native_width_shift)
		}
	}}
	bytes,err:=json.marshal(frames[:],{pretty=true},allocator=context.temp_allocator);assert(err==nil)
	assert(os.write_entire_file(fmt.tprintf("%s/frames.json",out),bytes)==nil)
	bytes,err=json.marshal(sweeps[:],{pretty=true},allocator=context.temp_allocator);assert(err==nil)
	assert(os.write_entire_file(fmt.tprintf("%s/sweeps.json",out),bytes)==nil)
	for frame in frames {for profile in frame.profiles {delete(profile.values);delete(profile.native_values)}}
}
