package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "rune:assets"
import "rune:ecs"
import bridge "rune:r3d_bridge"
import r3d "r3d:r3d"
import rl "vendor:raylib"

Output: string = "build/shadow-render-probe"
Width :: 800
Height :: 600

Result :: struct {
	label: string,
	depth_bias,slope_bias,range: f32,
	caster_height: f32,
	no_caster,grazing_receiver,vertical_receiver: bool,
	normal_mapped,forward_receiver,circle_receiver: bool,
	normal_texture_loaded,forward_material_loaded,custom_shader_loaded: bool,
	false_lit_reference_samples: int,
	max_lit_reference_drop: f64,
	shadow_enabled: bool,
	darker_pixels: int,
	max_luminance_drop,mean_luminance_drop: f64,
	shadow_sample_on,shadow_sample_off,lit_sample_on,lit_sample_off: f64,
	effective_depth_bias,effective_slope_bias: f32,
	shadow_sample_pixel,lit_sample_pixel: [2]int,
	on_path,off_path: string,
}

luma :: proc(color:rl.Color) -> f64 {
	return 0.2126*f64(color.r)+0.7152*f64(color.g)+0.0722*f64(color.b)
}

sample :: proc(image:rl.Image,point:[3]f32,camera:rl.Camera3D) -> (f64,[2]int) {
	pixel:=rl.GetWorldToScreenEx(point,camera,Width,Height)
	x,y:=int(pixel.x),int(pixel.y)
	assert(x>=1 && x<Width-1 && y>=1 && y<Height-1)
	colors:=rl.LoadImageColors(image); defer rl.UnloadImageColors(colors)
	value:f64
	for dy in -1..=1 {for dx in -1..=1 {value+=luma(colors[(y+dy)*Width+x+dx])}}
	return value/9,{x,y}
}

render :: proc(ctx:^bridge.Context,w:^ecs.World,m:^assets.Asset_Manager,path:string) -> rl.Image {
	for frame in 0..<3 {
		rl.BeginDrawing()
		rl.ClearBackground({20,24,30,255})
		assert(bridge.draw_scene_ex(ctx,w,m,{background_color={20,24,30,255}}))
		rl.EndDrawing()
	}
	image:=rl.LoadImageFromScreen()
	assert(rl.ExportImage(image,strings.clone_to_cstring(path,context.temp_allocator)))
	return image
}

main :: proc() {
	install_probe_crash_handler()
	if len(os.args)>1 {Output=os.args[1]}
	broad:=false
	map_size:i32=4096
	if len(os.args)>2 {for argument in os.args[2:] {
		if argument=="broad" {broad=true}
		if argument=="8192" {map_size=8192}
	}}
	assert(os.make_directory(Output)==nil || os.is_dir(Output))
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(Width,Height,"Rune actual shadow render probe"); defer rl.CloseWindow()
	r3d.SetHint(.SHADOW_DIR_SIZE,map_size)
	ctx,ready:=bridge.init(".",Width,Height); assert(ready); defer bridge.shutdown(&ctx)
	m:=assets.init("."); defer assets.shutdown(&m)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); assert(ecs.register_builtin_components(&r))
	w:=ecs.init(); defer ecs.destroy(&w)
	camera_entity:=ecs.create_entity(&w)
	camera:=rl.Camera3D{position={14,16,-24},target={0,0,-1},up={0,1,0},fovy=70}
	assert(ecs.add(&w,&r,camera_entity,ecs.Transform{position=camera.position,scale={1,1,1}}))
	assert(ecs.add(&w,&r,camera_entity,ecs.Camera3D{target=camera.target,up=camera.up,fovy=camera.fovy,active=true}))
	post:=ecs.default_post_processing(); post.anti_aliasing=.disabled
	assert(ecs.add(&w,&r,camera_entity,post))
	ambient:=ecs.create_entity(&w)
	assert(ecs.add(&w,&r,ambient,ecs.AmbientLight{color={255,255,255,255},intensity=0.08}))
	sun:=ecs.create_entity(&w)
	light:=ecs.DirectionalLight{direction={0.15,-0.55,-0.82},color={255,255,255,255},intensity=2.6,range=180,specular=0,
		shadows=true,shadow_softness=1.25,shadow_opacity=1,shadow_depth_bias=0.0002,shadow_slope_bias=0.004}
	assert(ecs.add(&w,&r,sun,light))
	floor:=ecs.create_entity(&w)
	assert(ecs.add(&w,&r,floor,ecs.Transform{position={0,-0.1,0},scale={30,0.2,30}}))
	assert(ecs.add(&w,&r,floor,ecs.MeshRenderer{primitive="cube",color={180,180,180,255},shadows=false}))
	caster:=ecs.create_entity(&w)
	assert(ecs.add(&w,&r,caster,ecs.Transform{position={0,2,0},scale={4,4,4}}))
	assert(ecs.add(&w,&r,caster,ecs.MeshRenderer{primitive="cube",color={210,180,150,255},shadows=true}))
	// Distinct geometric and shading normals make wrong receiver-plane normals
	// observable. Keep the map deterministic and the alpha variants fully opaque.
	normal_path:=fmt.tprintf("%s/normal.png",Output)
	normal_image:=rl.GenImageColor(8,8,{128,80,230,255})
	assert(rl.ExportImage(normal_image,strings.clone_to_cstring(normal_path,context.temp_allocator)))
	rl.UnloadImage(normal_image)
	material_paths:[4]string
	for i in 0..<4 {
		material_paths[i]=fmt.tprintf("%s/material-%d.material.json",Output,i)
		normal:=normal_path if i&1!=0 else ""
		transparency:="alpha" if i&2!=0 else "disabled"
		material:=struct {base_color:[4]u8,lighting:bool,roughness,metallic:f32,normal:string,normal_scale:f32,transparency:string}{
			{180,180,180,255},true,1,0,normal,1,transparency}
		bytes,err:=json.marshal(material,allocator=context.temp_allocator); assert(err==nil)
		assert(os.write_entire_file(material_paths[i],bytes)==nil)
		_,loaded:=assets.material_data(&m,material_paths[i]); assert(loaded,"diagnostic material must load rather than fall back")
	}
	circle_source::`void fragment() { if (length(TEXCOORD * 2.0 - 1.0) > 1.0) discard; }`
	circle:=r3d.LoadSurfaceShaderFromMemory(circle_source); assert(circle!=nil); defer r3d.UnloadSurfaceShader(circle)
	results:=make([dynamic]Result); defer delete(results)
	cases:=make([dynamic]Result); defer delete(cases)
	for input in ([]Result{
		{label="shipped",depth_bias=0.0002,slope_bias=0.004,range=180,caster_height=4},
		{label="lower-slope",depth_bias=0.0002,slope_bias=0.0015,range=180,caster_height=4},
		{label="zero-bias",depth_bias=0,slope_bias=0,range=180,caster_height=4},
		{label="short-range",depth_bias=0.0002,slope_bias=0.004,range=30,caster_height=4},
		{label="long-range",depth_bias=0.0002,slope_bias=0.004,range=1000,caster_height=4},
	}) {append(&cases,input)}
	for height in ([3]f32{0.2,0.5,2}) {
		for slope in ([4]f32{0.004,0.0015,0.0003,0.0001}) {
			append(&cases,Result{label=fmt.tprintf("height-%.1f-slope-%.4f",height,slope),depth_bias=0.0002,slope_bias=slope,range=180,caster_height=height})
		}
	}
	for slope in ([4]f32{0.004,0.0015,0.0003,0.0001}) {
		append(&cases,Result{label=fmt.tprintf("grazing-receiver-slope-%.4f",slope),depth_bias=0.0002,slope_bias=slope,range=180,caster_height=4,no_caster=true,grazing_receiver=true})
	}
	for height in ([4]f32{0,0.2,0.5,2}) {
		for slope in ([6]f32{0.004,0.0015,0.0003,0.0001,0.00005,0}) {
			append(&cases,Result{label=fmt.tprintf("vertical-height-%.1f-slope-%.5f",height,slope),depth_bias=0.0002,slope_bias=slope,range=180,
				caster_height=height,no_caster=height==0,grazing_receiver=true,vertical_receiver=true})
		}
	}
	append(&cases,Result{label="final-floor-0.2",depth_bias=0.00005,slope_bias=0.0001,range=180,caster_height=0.2})
	append(&cases,Result{label="final-grazing-floor",depth_bias=0.00005,slope_bias=0.0001,range=180,caster_height=4,no_caster=true,grazing_receiver=true})
	for height in ([3]f32{0,0.2,0.5}) {
		append(&cases,Result{label=fmt.tprintf("final-vertical-%.1f",height),depth_bias=0.00005,slope_bias=0.0001,range=180,
			caster_height=height,no_caster=height==0,grazing_receiver=true,vertical_receiver=true})
	}
	for mode in 0..<4 {for height in ([2]f32{0,0.2}) {
		append(&cases,Result{label=fmt.tprintf("final-material-%d-height-%.1f",mode,height),depth_bias=0.00005,slope_bias=0.0001,range=180,
			caster_height=height,no_caster=height==0,grazing_receiver=true,vertical_receiver=true,
			normal_mapped=mode==0 || mode==2,forward_receiver=mode>=1,circle_receiver=mode==3})
	}}
	for input in cases {
		if !broad && !strings.has_prefix(input.label,"final-") {continue}
		result:=input
		shadow_point:=[3]f32{0.8,0.01,-4.5}
		lit_point:=[3]f32{-8,0.01,-4.5}
		if result.caster_height<4 {
			camera.position={0,24,-16}; camera.target={0,0,-1}
			shadow_point={0,0.01,-2-0.82/0.55*result.caster_height*0.9}
		} else {camera.position={14,16,-24}; camera.target={0,0,-1}}
		w.transforms[camera_entity]=ecs.Transform{position=camera.position,scale={1,1,1}}
		assert(ecs.set_camera_3d(&w,camera_entity,ecs.Camera3D{target=camera.target,up=camera.up,fovy=camera.fovy,active=true}))
		w.transforms[caster]=ecs.Transform{position={0,result.caster_height/2,0},scale={4,result.caster_height,4}}
		w.transforms[floor]=ecs.Transform{position={0,-0.1,0},scale={30,0.2,30}}
		if result.vertical_receiver {
			camera.position={-24,0,-16}; camera.target={0,0,-1}
			w.transforms[camera_entity]=ecs.Transform{position=camera.position,scale={1,1,1}}
			assert(ecs.set_camera_3d(&w,camera_entity,ecs.Camera3D{target=camera.target,up=camera.up,fovy=camera.fovy,active=true}))
			w.transforms[floor]=ecs.Transform{position={0.1,0,0},rotation={0,0,90},scale={30,0.2,30}}
			w.transforms[caster]=ecs.Transform{position={-result.caster_height/2,0,0},rotation={0,0,90},scale={4,max(result.caster_height,0.01),4}}
			shadow_point={-0.01,-0.55/0.15*result.caster_height*0.8,-2-0.82/0.15*result.caster_height*0.8}
			lit_point={-0.01,8,-4.5}
		}
		ecs.set_enabled(&w,caster,!result.no_caster)
		floor_mesh:=w.mesh_renderers[floor]; floor_mesh.shadows=result.grazing_receiver
		floor_mesh.material=""
		if result.normal_mapped || result.forward_receiver || result.circle_receiver {
			index:=1 if result.normal_mapped else 0
			if result.forward_receiver {index+=2}
			floor_mesh.material=material_paths[index]
			material:=bridge.material_from_path(&ctx,&m,floor_mesh.material,floor_mesh.color)
			if result.normal_mapped {
				result.normal_texture_loaded=ctx.r3d_materials[floor_mesh.material].owns_normal
				assert(result.normal_texture_loaded,"normal-map test must load its actual texture")
			}
			if result.forward_receiver {
				result.forward_material_loaded=material.transparencyMode==.ALPHA
				assert(result.forward_material_loaded,"forward test must use alpha material routing")
			}
			if result.circle_receiver {
				cached:=ctx.r3d_materials[floor_mesh.material]; cached.material.shader=circle
				ctx.r3d_materials[floor_mesh.material]=cached
				result.custom_shader_loaded=cached.material.shader==circle
			}
		}
		w.mesh_renderers[floor]=floor_mesh
		light.direction={-0.82,-0.15,-0.55} if result.grazing_receiver && !result.vertical_receiver else {0.15,-0.55,-0.82}
		light.range=result.range; light.shadow_depth_bias=result.depth_bias; light.shadow_slope_bias=result.slope_bias
		light.shadow_overrides.depth_bias=result.depth_bias; light.shadow_overrides.slope_bias=result.slope_bias
		light.shadows_disabled=false; assert(ecs.set_directional_light(&w,sun,light))
		result.on_path=fmt.tprintf("%s/%s-on.png",Output,result.label)
		on:=render(&ctx,&w,&m,result.on_path); defer rl.UnloadImage(on)
		id:=ctx.scene_lights[sun]
		result.shadow_enabled=r3d.IsShadowEnabled(id)
		result.effective_depth_bias=r3d.GetShadowDepthBias(id); result.effective_slope_bias=r3d.GetShadowSlopeBias(id)
		assert(result.shadow_enabled)
		light.shadows_disabled=true; assert(ecs.set_directional_light(&w,sun,light))
		result.off_path=fmt.tprintf("%s/%s-off.png",Output,result.label)
		off:=render(&ctx,&w,&m,result.off_path); defer rl.UnloadImage(off)
		assert(!r3d.IsShadowEnabled(id))
		on_pixels:=rl.LoadImageColors(on); defer rl.UnloadImageColors(on_pixels)
		off_pixels:=rl.LoadImageColors(off); defer rl.UnloadImageColors(off_pixels)
		for i in 0..<Width*Height {
			drop:=luma(off_pixels[i])-luma(on_pixels[i])
			if drop>10 {result.darker_pixels+=1}
			result.max_luminance_drop=max(result.max_luminance_drop,drop)
			result.mean_luminance_drop+=drop/f64(Width*Height)
		}
		result.shadow_sample_on,result.shadow_sample_pixel=sample(on,shadow_point,camera)
		result.shadow_sample_off,_=sample(off,shadow_point,camera)
		result.lit_sample_on,result.lit_sample_pixel=sample(on,lit_point,camera)
		result.lit_sample_off,_=sample(off,lit_point,camera)
		if result.vertical_receiver {
			// Entire grid lies above the cube and its downward sun shadow.
			// This isolates receiver acne while retaining the actual thin caster.
			for y in 0..<17 {for z in 0..<25 {
				point:=[3]f32{-0.01,6+f32(y)*0.25,-6+f32(z)*0.5}
				pixel:=rl.GetWorldToScreenEx(point,camera,Width,Height)
				index:=int(pixel.y)*Width+int(pixel.x)
				drop:=luma(off_pixels[index])-luma(on_pixels[index])
				if drop>5 {result.false_lit_reference_samples+=1}
				result.max_lit_reference_drop=max(result.max_lit_reference_drop,drop)
			}}
		}
		append(&results,result)
		fmt.println(result)
	}
	bytes,err:=json.marshal(results[:],{pretty=true},allocator=context.temp_allocator); assert(err==nil)
	assert(os.write_entire_file(fmt.tprintf("%s/results.json",Output),bytes)==nil)
	if !broad {
		for result in results {
			if result.no_caster {
				assert(result.darker_pixels<=4,"unoccluded grazing receiver must remain free of broad shadow acne")
				assert(result.max_luminance_drop<=5,"unoccluded receiver must not acquire dark bands")
			} else {
				assert(result.darker_pixels>=100,"thin caster must produce a measurable shadow area")
				assert(result.max_luminance_drop>=10,"thin caster must retain visible shadow contrast")
			}
			assert(result.false_lit_reference_samples==0,"the known lit receiver region must not gain false shadows")
		}
		fmt.println("Actual directional shadow visibility and grazing receiver checks passed",len(results),"render pairs")
	}
}
