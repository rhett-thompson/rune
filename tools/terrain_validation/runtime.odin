package main

import "core:fmt"
import "core:encoding/json"
import "core:os"
import "core:strings"
import "rune:assets"
import "rune:ecs"
import "rune:terrain"
import bridge "rune:r3d_bridge"
import rl "vendor:raylib"
import r3d "r3d:r3d"
import "vendor:raylib/rlgl"

render_frame :: proc(ctx:^bridge.Context,w:^ecs.World,manager:^assets.Asset_Manager) {
	rl.BeginDrawing()
	rl.ClearBackground(rl.BLACK)
	assert(bridge.draw_scene(ctx,w,manager))
	rl.EndDrawing()
}

validate_runtime :: proc() {
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(640,360,"Terrain GPU validation")
	defer rl.CloseWindow()
	manager := assets.init(".")
	defer assets.shutdown(&manager)
	ctx,ready := bridge.init(".",640,360); assert(ready)
	defer bridge.shutdown(&ctx)
	r3d.SetAntiAliasingMode(.NONE)
	r := ecs.init_registry(); defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	w := ecs.init(); defer ecs.destroy(&w)
	camera := ecs.create_entity(&w)
	assert(add_transform(&w,&r,camera,{position={20,16,24},scale={1,1,1}}))
	assert(ecs.add_component(&w,&r,camera,"Camera3D",parse(`{"active":true,"target":[8,2,8]}`)))
	e := ecs.create_entity(&w)
	assert(add_transform(&w,&r,e,{scale={1,1,1}}))
	t := ecs.default_terrain(); t.asset="build/terrain-test.terrain.json"
	assert(ecs.add(&w,&r,e,t))
	ecs.sync_terrains(&w,&manager)
	render_frame(&ctx,&w,&manager)
	cache,found := ctx.terrains[e]
	assert(found && len(cache.chunks)==4,"four terrain render chunks")
	indices:i32
	for mesh in cache.chunks {indices += mesh.indexCount}
	assert(indices==16*16*6,"all terrain cells uploaded once")
	initial := cache.revision
	assert(write_fixture("build/terrain-test.terrain.json",`{"heightmap":"build/terrain-test.r16","resolution":[17,17],"size":[16,16],"height_scale":16,"height_offset":4,"chunk_cells":16}`)==nil)
	assets.refresh_terrains(&manager)
	ecs.sync_terrains(&w,&manager)
	render_frame(&ctx,&w,&manager)
	cache=ctx.terrains[e]
	assert(cache.revision>initial && len(cache.chunks)==1,"successful reload replaces GPU chunks")
	initial=cache.revision
	assert(write_fixture("build/terrain-test.terrain.json","invalid")==nil)
	assets.refresh_terrains(&manager)
	ecs.sync_terrains(&w,&manager)
	render_frame(&ctx,&w,&manager)
	assert(ctx.terrains[e].revision==initial,"invalid reload keeps GPU chunks")
	assert(ecs.remove_component(&w,e,"Terrain"))
	render_frame(&ctx,&w,&manager)
	assert(len(ctx.terrains)==0,"removed terrain releases GPU cache")
	// Restore descriptor; a missing/invalid first asset can recover too.
	assert(write_fixture("build/terrain-test.terrain.json",`{"heightmap":"build/terrain-test.r16","resolution":[17,17],"size":[16,16],"height_scale":16,"chunk_cells":8}`)==nil)
	assets.refresh_terrains(&manager)
	assert(len(manager.diagnostics.reported)==0,"repair clears diagnostics even when failed descriptor had no heightmap path")
	assert(ecs.add(&w,&r,e,t)); ecs.sync_terrains(&w,&manager)
	render_frame(&ctx,&w,&manager)
	other := ecs.init(); defer ecs.destroy(&other)
	rl.BeginDrawing()
	bridge.draw_scene(&ctx,&other,&manager)
	rl.EndDrawing()
	assert(len(ctx.terrains)==0,"world generation clears terrain GPU cache")
	fmt.println("PASS runtime terrain drawing, GPU topology, valid/invalid reloads, removal and scene replacement")
	validate_eight_layers(&ctx,&manager,&r)
	validate_blend_runtime(&ctx,&manager,&r)
	validate_detail_rendering(&ctx,&manager,&r)
	validate_material_landscape(&ctx,&r)
}

validate_material_landscape :: proc(ctx:^bridge.Context,r:^ecs.Component_Registry) {
	manager := assets.init("examples/terrain_3d"); defer assets.shutdown(&manager)
	w := ecs.init(); defer ecs.destroy(&w)
	e := ecs.create_entity(&w)
	assert(add_transform(&w,r,e,{scale={1,1,1}}))
	t := ecs.default_terrain(); t.asset="assets/hills.terrain.json"
	assert(ecs.add(&w,r,e,t)); ecs.sync_terrains(&w,&manager)
	camera := ecs.create_entity(&w)
	assert(add_transform(&w,r,camera,{position={185,80,210},scale={1,1,1}}))
	assert(ecs.add_component(&w,r,camera,"Camera3D",parse(`{"active":true,"target":[110,12,100],"fovy":65}`)))
	sun := ecs.create_entity(&w)
	assert(ecs.add_component(&w,r,sun,"DirectionalLight",parse(`{"direction":[-1,-0.7,-0.4],"energy":3,"shadows":true}`)))
	ambient := ecs.create_entity(&w)
	assert(ecs.add_component(&w,r,ambient,"AmbientLight",parse(`{"color":[153,183,210,255],"energy":0.45}`)))
	sky := ecs.create_entity(&w)
	assert(ecs.add_component(&w,r,sky,"Skybox",parse(`{"mode":"procedural"}`)))
	blend_center_pixel(ctx,&w,&manager,output="build/terrain-material-landscape.png")
	data,_,_:=ecs.terrain_runtime(&w,e)
	height,_:=terrain.sample_height(data,128,190)
	pose,_:=ecs.get_transform(&w,camera); pose.position={128,height+2.5,190}
	assert(ecs.set_transform(&w,camera,pose))
	view,_:=ecs.get_camera_3d(&w,camera); view.target={128,height+1,174}
	assert(ecs.set_camera_3d(&w,camera,view))
	blend_center_pixel(ctx,&w,&manager,output="build/terrain-details-close.png")
	assert(len(manager.diagnostics.reported)==0,"example material layers load cleanly")
	fmt.println("PASS procedural terrain landscape render")
}

validate_blend_runtime :: proc(ctx:^bridge.Context,manager:^assets.Asset_Manager,r:^ecs.Component_Registry) {
	// Solid primary colors make layer selection and mixing observable in pixels.
	paths := [3]string{"build/terrain-grass.png","build/terrain-dirt.png","build/terrain-rock.png"}
	colors := [3]rl.Color{{255,0,0,255},{0,255,0,255},{0,0,255,255}}
	for path,i in paths {
		image := rl.GenImageColor(4,4,colors[i])
		assert(rl.ExportImage(image,strings.clone_to_cstring(path,context.temp_allocator)))
		rl.UnloadImage(image)
	}
	assert(write_fixture("build/terrain-blend.material.json",`{"base_color":[255,255,255,255],"lighting":false}`)==nil)
	d := terrain.default_description()
	d.heightmap="build/terrain-test.r16"; d.resolution={17,17}; d.size={16,16}; d.height_scale=0
	d.material="build/terrain-blend.material.json"
	d.blend.grass,d.blend.dirt,d.blend.rock=paths[0],paths[1],paths[2]
	d.blend.dirt_height={-2,-1}; d.blend.rock_slope={60,80}; d.blend.noise_strength=0
	path := "build/terrain-blend-runtime.terrain.json"
	bytes,_ := json.marshal(d,allocator=context.temp_allocator)
	assert(write_fixture(path,bytes)==nil)
	w := ecs.init(); defer ecs.destroy(&w)
	camera := ecs.create_entity(&w)
	assert(add_transform(&w,r,camera,{position={8,30,8},scale={1,1,1}}))
	assert(ecs.add_component(&w,r,camera,"Camera3D",parse(`{"active":true,"target":[8,0,8],"up":[0,0,-1],"fovy":40}`)))
	e := ecs.create_entity(&w)
	assert(add_transform(&w,r,e,{scale={1,1,1}}))
	t := ecs.default_terrain(); t.asset=path
	assert(ecs.add(&w,r,e,t))
	ecs.sync_terrains(&w,manager)
	render_frame(ctx,&w,manager)
	assert(ctx.terrains[e].blend_shader!=nil,"blend surface shader compiles")
	pixel := blend_center_pixel(ctx,&w,manager)
	assert(pixel.r>150 && pixel.g<30 && pixel.b<30,"high flat ground selects grass")
	for heights,index in ([2][2]f32{{-1,1},{1,2}}) {
		d.blend.dirt_height=heights
		bytes,_ = json.marshal(d,allocator=context.temp_allocator)
		assert(write_fixture(path,bytes)==nil)
		assets.refresh_terrains(manager); ecs.sync_terrains(&w,manager)
		render_frame(ctx,&w,manager)
		pixel=blend_center_pixel(ctx,&w,manager)
		if index==0 {assert(pixel.r>70 && pixel.g>70 && pixel.b<30,"transition mixes grass and dirt")}
		else {assert(pixel.g>150 && pixel.r<30 && pixel.b<30,"low ground selects dirt after reload")}
	}
	d.blend.dirt_height={-1,1}; d.blend.noise_strength=0.8
	bytes,_ = json.marshal(d,allocator=context.temp_allocator)
	assert(write_fixture(path,bytes)==nil)
	assets.refresh_terrains(manager); ecs.sync_terrains(&w,manager)
	blend_center_pixel(ctx,&w,manager,check_noise=true)
	d.blend.noise_strength=0
	// A tilted heightfield must select rock without changing collision topology.
	d.height_scale=16; d.blend.rock_slope={1,2}
	bytes,_ = json.marshal(d,allocator=context.temp_allocator)
	assert(write_fixture(path,bytes)==nil)
	assets.refresh_terrains(manager); ecs.sync_terrains(&w,manager)
	render_frame(ctx,&w,manager)
	pixel=blend_center_pixel(ctx,&w,manager)
	assert(pixel.b>150 && pixel.r<30 && pixel.g<30,"steep ground selects rock")
	// A second terrain must not share mutable uniform/sampler state.
	other := ecs.create_entity(&w)
	assert(add_transform(&w,r,other,{position={20,0,0},scale={1,1,1}}))
	assert(ecs.add(&w,r,other,t)); ecs.sync_terrains(&w,manager)
	render_frame(ctx,&w,manager)
	assert(ctx.terrains[e].blend_shader!=ctx.terrains[other].blend_shader,"independent per-entity shader state")
	// Material layers can coexist with image layers and regenerate independently.
	material_paths := [3]string{"build/terrain-grass.material.json","build/terrain-dirt.material.json","build/terrain-rock.material.json"}
	for layer_path,i in material_paths {
		write_layer_fixture(layer_path,colors[i],roughness=0.2+f32(i)*0.3,metallic=f32(i)*0.5)
	}
	d.height_scale=0; d.blend.dirt_height={-2,-1}; d.blend.rock_slope={60,80}
	d.blend.grass,d.blend.dirt,d.blend.rock=material_paths[0],material_paths[1],material_paths[2]
	bytes,_=json.marshal(d,allocator=context.temp_allocator)
	assert(write_fixture(path,bytes)==nil)
	assets.refresh_terrains(manager); ecs.sync_terrains(&w,manager)
	pixel=blend_center_pixel(ctx,&w,manager)
	assert(pixel.r>150 && pixel.g<30 && pixel.b<30,"procedural material selects grass color")
	assert(write_fixture("build/terrain-blend.material.json",`{"base_color":[255,255,255,255],"lighting":true}`)==nil)
	assets.refresh_materials(manager)
	r3d.SetOutputMode(.ORM)
	pixel=blend_center_pixel(ctx,&w,manager)
	assert(pixel.r==255 && abs(int(pixel.g)-51)<3 && pixel.b==0,"grass ORM uses layer scalars")
	r3d.SetOutputMode(.NORMAL)
	pixel=blend_center_pixel(ctx,&w,manager)
	assert(abs(int(pixel.r)-127)<2 && pixel.g>253 && abs(int(pixel.b)-127)<2,"flat layer preserves terrain normal")
	// File overrides, material edits and invalid edits reuse terrain geometry.
	revision := ctx.terrains[e].revision
	shader := ctx.terrains[e].blend_shader
	image := rl.GenImageColor(8,8,{218,128,218,255})
	assert(rl.ExportImage(image,"build/terrain-normal.png")); rl.UnloadImage(image)
	write_layer_fixture(material_paths[0],rl.YELLOW,roughness=0.2,normal="build/terrain-normal.png")
	assets.refresh_materials(manager)
	pixel=blend_center_pixel(ctx,&w,manager)
	assert(pixel.r>200 && pixel.g>190 && pixel.g<240,"layer normal override tilts terrain normal")
	r3d.SetOutputMode(.ALBEDO)
	pixel=blend_center_pixel(ctx,&w,manager)
	assert(pixel.r>240 && pixel.g>100 && pixel.b<10,"live material color edit updates blend")
	atlas := ctx.terrain_layers[material_paths[0]].texture.id
	assert(write_fixture(material_paths[0],"invalid")==nil)
	assets.refresh_materials(manager)
	retained := blend_center_pixel(ctx,&w,manager)
	assert(retained==pixel && ctx.terrain_layers[material_paths[0]].texture.id==atlas,"invalid layer reload retains working atlas")
	assert(ctx.terrains[e].revision==revision && ctx.terrains[e].blend_shader==shader,"layer reload preserves terrain geometry and shader")
	// Transition pixels interpolate physical channels as well as color.
	write_layer_fixture(material_paths[0],rl.RED,roughness=0.2)
	assets.refresh_materials(manager)
	d.blend.dirt_height={-1,1}
	bytes,_=json.marshal(d,allocator=context.temp_allocator); assert(write_fixture(path,bytes)==nil)
	assets.refresh_terrains(manager); ecs.sync_terrains(&w,manager)
	r3d.SetOutputMode(.ORM)
	pixel=blend_center_pixel(ctx,&w,manager)
	assert(abs(int(pixel.g)-89)<3 && abs(int(pixel.b)-64)<3,"grass/dirt transition blends roughness and metalness")
	// A plain image can share the material blend and keep base surface scalars.
	d.blend.dirt=paths[1]; d.blend.dirt_height={1,2}
	bytes,_=json.marshal(d,allocator=context.temp_allocator); assert(write_fixture(path,bytes)==nil)
	assets.refresh_terrains(manager); ecs.sync_terrains(&w,manager)
	r3d.SetOutputMode(.ALBEDO)
	pixel=blend_center_pixel(ctx,&w,manager)
	assert(pixel.g>240 && pixel.r<10 && pixel.b<10,"mixed image/material blend selects image color")
	// Magnified checker texels distinguish point sampling from bilinear sampling.
	image=rl.GenImageChecked(8,8,1,1,rl.BLACK,rl.WHITE)
	assert(rl.ExportImage(image,"build/terrain-checker.png")); rl.UnloadImage(image)
	d.blend.dirt_height={-2,-1}; d.uv_scale={1,1}
	bytes,_=json.marshal(d,allocator=context.temp_allocator); assert(write_fixture(path,bytes)==nil)
	assets.refresh_terrains(manager); ecs.sync_terrains(&w,manager)
	write_layer_fixture(material_paths[0],rl.WHITE,bump=0.2)
	assets.refresh_materials(manager)
	r3d.SetOutputMode(.NORMAL)
	normal_colors:int
	blend_center_pixel(ctx,&w,manager,unique_red=&normal_colors)
	assert(normal_colors>2,"generated layer bumps visibly vary terrain normals")
	r3d.SetOutputMode(.ALBEDO)
	write_layer_fixture(material_paths[0],rl.WHITE,texture="build/terrain-checker.png")
	assets.refresh_materials(manager)
	point_colors,filtered_colors:int
	blend_center_pixel(ctx,&w,manager,unique_red=&point_colors,output="build/terrain-point.png")
	write_layer_fixture(material_paths[0],rl.WHITE,texture="build/terrain-checker.png",filter="bilinear")
	assets.refresh_materials(manager)
	blend_center_pixel(ctx,&w,manager,unique_red=&filtered_colors,output="build/terrain-filtered.png")
	assert(point_colors<=2 && filtered_colors>8,"point filtering preserves texels independently of resolution")
	assert(ctx.terrain_layers[material_paths[0]].texture.width==8,"filter change preserves layer resolution")
	atlas=ctx.terrain_layers[material_paths[0]].texture.id
	assert(write_fixture("build/terrain-checker.png","invalid")==nil)
	assets.refresh_materials(manager)
	blend_center_pixel(ctx,&w,manager)
	assert(ctx.terrain_layers[material_paths[0]].texture.id==atlas,"broken layer image retains previous atlas")
	image=rl.GenImageChecked(8,8,1,1,rl.BLACK,rl.WHITE)
	assert(rl.ExportImage(image,"build/terrain-checker.png")); rl.UnloadImage(image)
	// Minification must not leak the adjacent normal/ORM atlas cells into albedo.
	d.uv_scale={2048,2048}
	bytes,_=json.marshal(d,allocator=context.temp_allocator); assert(write_fixture(path,bytes)==nil)
	assets.refresh_terrains(manager); ecs.sync_terrains(&w,manager)
	write_layer_fixture(material_paths[0],rl.WHITE,texture="build/terrain-checker.png",filter="anisotropic_8x",mipmaps=true)
	assets.refresh_materials(manager)
	pixel=blend_center_pixel(ctx,&w,manager)
	assert(abs(int(pixel.r)-int(pixel.g))<2 && abs(int(pixel.r)-int(pixel.b))<2 && pixel.r>20 && pixel.r<220,"distant mips preserve neutral albedo without atlas bleeding")
	r3d.SetOutputMode(.SCENE)
	// Invalid descriptor retains the already-rendered blend; disabling releases it.
	old := ctx.terrains[e].blend_shader
	assert(write_fixture(path,`{"blend":{"rock_slope":[30,10]}}`)==nil)
	assets.refresh_terrains(manager); ecs.sync_terrains(&w,manager)
	render_frame(ctx,&w,manager)
	assert(ctx.terrains[e].blend_shader==old,"bad reload retains blend shader")
	d.blend=terrain.default_blend()
	bytes,_ = json.marshal(d,allocator=context.temp_allocator)
	assert(write_fixture(path,bytes)==nil)
	assets.refresh_terrains(manager); ecs.sync_terrains(&w,manager)
	render_frame(ctx,&w,manager)
	assert(ctx.terrains[e].blend_shader==nil,"disabling blend releases shader")
	assert(ecs.destroy_entity(&w,e) && ecs.destroy_entity(&w,other))
	render_frame(ctx,&w,manager)
	assert(len(ctx.terrains)==0,"removal releases blended terrain caches")
	fmt.println("PASS terrain image/material blending, normals, ORM, point filtering, mip isolation, reload retention and cleanup")
}

write_layer_fixture :: proc(path:string,color:rl.Color,roughness:f32=0.5,metallic:f32=0,normal:string="",texture:string="",filter:string="point",mipmaps:bool=false,bump:f32=0) {
	data := struct {
		base_color:[4]u8,
		roughness,metallic:f32,
		normal,texture,filter:string,
		mipmaps:bool,
		procedural:struct{resolution,scale:int,color_a,color_b:[4]u8,bump_strength,roughness_variation:f32},
	}{base_color={255,255,255,255},roughness=roughness,metallic=metallic,normal=normal,texture=texture,filter=filter,mipmaps=mipmaps,
		procedural={resolution=8,scale=2,color_a={color.r,color.g,color.b,color.a},color_b={color.r,color.g,color.b,color.a},bump_strength=bump}}
	bytes,error := json.marshal(data,allocator=context.temp_allocator); assert(error==nil)
	assert(write_fixture(path,bytes)==nil)
}

blend_center_pixel :: proc(ctx:^bridge.Context,w:^ecs.World,manager:^assets.Asset_Manager,check_noise:=false,unique_red:^int=nil,output:string="") -> rl.Color {
	rl.BeginDrawing()
	defer rl.EndDrawing()
	assert(bridge.draw_scene(ctx,w,manager))
	rlgl.DrawRenderBatchActive()
	image := rl.LoadImageFromScreen()
	defer rl.UnloadImage(image)
	if output!="" {assert(rl.ExportImage(image,strings.clone_to_cstring(output,context.temp_allocator)))}
	if unique_red!=nil {
		seen:[256]bool
		for x:i32=200; x<440; x+=1 {seen[rl.GetImageColor(image,x,image.height/2+9).r]=true}
		unique_red^=0
		for used in seen {if used {unique_red^+=1}}
	}
	if check_noise {
		min_red,max_red := 255,0
		for y := image.height/2-64; y<image.height/2+64; y+=1 {
			for x := image.width/2-64; x<image.width/2+64; x+=1 {
				p := rl.GetImageColor(image,x,y)
				min_red,max_red=min(min_red,int(p.r)),max(max_red,int(p.r))
				for offset in ([2][2]i32{{1,0},{0,1}}) {
					n := rl.GetImageColor(image,x+offset[0],y+offset[1])
					assert(abs(int(p.r)-int(n.r))<30 && abs(int(p.g)-int(n.g))<30,"noise remains continuous across lattice boundaries")
				}
			}
		}
		assert(max_red-min_red>8,"noise visibly varies the blend")
	}
	return rl.GetImageColor(image,image.width/2,image.height/2)
}
