package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "rune:assets"
import "rune:ecs"
import "rune:terrain"
import bridge "rune:r3d_bridge"
import rl "vendor:raylib"
import r3d "r3d:r3d"

validate_layer_list :: proc() {
	prefix:=`{"heightmap":"tools/terrain_validation/fixtures/precision.png","resolution":[2,2],`
	path:="build/layer-list.terrain.json"
	for fields in ([]string{
		`"layers":null`,
		`"layers":[{}]`,
		`"layers":[{"material":"x","unexpected":true}]`,
		`"layers":[{"material":"x","tile_size":[0,4]}]`,
		`"layers":[{"material":"x","height":[0,2,1,3]}]`,
		`"layers":[{"material":"x","slope":[0,1,2]}]`,
		`"layers":[{"material":"x","weight":-1}]`,
		`"layers":[{"material":"x"}],"control_maps":["a.png","b.png"]`,
		`"control_maps":["a.png"]`,
		`"layers":[{"material":"x"}],"blend":{"grass":"a","dirt":"b","rock":"c"}`,
	}) {
		assert(write_fixture(path,fmt.tprint(prefix,fields,"}"))==nil)
		data,_,error:=terrain.load(".",path); assert(error!="","reject malformed layer settings"); terrain.destroy(&data)
	}
	d:=terrain.default_description(); d.heightmap="tools/terrain_validation/fixtures/precision.png"; d.resolution={2,2}
	layers:[9]terrain.Layer
	for &layer in layers {layer=terrain.default_layer(); layer.material="test.material.json"}
	d.layers=layers[:]
	bytes,_:=json.marshal(d,allocator=context.temp_allocator); assert(write_fixture(path,bytes)==nil)
	data,_,error:=terrain.load(".",path); assert(error!="","reject ninth layer"); terrain.destroy(&data)
	assert(write_fixture(path,fmt.tprint(prefix,`"layers":[{"name":"Base","material":"base.material.json"}]} `))==nil)
	data,_,error=terrain.load(".",path); assert(error=="",error)
	assert(data.description.layers[0].weight==1 && data.description.layers[0].tile_size==[2]f32{4,4},"layer defaults")
	copy:=terrain.clone(data); terrain.destroy(&data)
	assert(copy.description.layers[0].name=="Base" && copy.description.layers[0].material=="base.material.json","layer strings survive source destruction")
	terrain.destroy(&copy)
	fmt.println("PASS layer-list bounds, defaults, malformed rules and clone ownership")
}

validate_eight_layers :: proc(ctx:^bridge.Context,manager:^assets.Asset_Manager,r:^ecs.Component_Registry) {
	d:=terrain.default_description()
	d.heightmap="build/terrain-test.r16"; d.resolution={17,17}; d.size={16,16}; d.height_scale=0
	d.material="build/eight-base.material.json"
	assert(write_fixture(d.material,`{"base_color":[255,255,255,255],"lighting":true}`)==nil)
	layers:[8]terrain.Layer
	colors:=[8]rl.Color{{255,0,0,255},{0,255,0,255},{0,0,255,255},{255,255,0,255},{255,0,255,255},{0,255,255,255},{255,255,255,255},{0,0,0,255}}
	for &layer,i in layers {
		layer=terrain.default_layer()
		layer.material=fmt.tprintf("build/eight-layer-%d.material.json",i)
		write_layer_fixture(layer.material,colors[i],roughness=f32(i+1)/10,metallic=f32(i)/7)
	}
	d.layers=layers[:]
	path:="build/eight-layers.terrain.json"
	w:=ecs.init(); defer ecs.destroy(&w)
	camera:=ecs.create_entity(&w)
	assert(add_transform(&w,r,camera,{position={8,30,8},scale={1,1,1}}))
	assert(ecs.add_component(&w,r,camera,"Camera3D",parse(`{"active":true,"target":[8,0,8],"up":[0,0,-1],"fovy":40}`)))
	e:=ecs.create_entity(&w)
	assert(add_transform(&w,r,e,{scale={1,1,1}}))
	t:=ecs.default_terrain(); t.asset=path
	assert(ecs.add(&w,r,e,t))
	r3d.SetOutputMode(.ALBEDO)
	for expected,index in colors {
		for &layer,i in layers {layer.weight=1 if i==index else 0}
		bytes,_:=json.marshal(d,allocator=context.temp_allocator); assert(write_fixture(path,bytes)==nil)
		assets.refresh_terrains(manager); ecs.sync_terrains(&w,manager)
		pixel:=blend_center_pixel(ctx,&w,manager)
		assert(pixel==expected,fmt.tprintf("eight-layer slot %d selects its color: %v != %v",index,pixel,expected))
	}
	r3d.SetOutputMode(.ORM)
	pixel:=blend_center_pixel(ctx,&w,manager)
	assert(abs(int(pixel.g)-204)<3 && pixel.b>253,"eighth layer retains roughness and metalness")
	// Each RGBA channel maps to a separate layer, including A and layers 5-8.
	for &layer in layers {layer.weight=1}
	controls:=[2]string{"build/eight-control-0.png","build/eight-control-1.png"}
	d.control_maps=controls[:]
	for expected,index in colors {
		for control,group in controls {
			channels:[4]u8
			if index/4==group {channels[index%4]=255}
			image:=rl.GenImageColor(1,1,{channels[0],channels[1],channels[2],channels[3]})
			assert(rl.ExportImage(image,strings.clone_to_cstring(control,context.temp_allocator))); rl.UnloadImage(image)
		}
		if index==0 {
			bytes,_:=json.marshal(d,allocator=context.temp_allocator); assert(write_fixture(path,bytes)==nil)
			assets.refresh_terrains(manager); ecs.sync_terrains(&w,manager)
		}
		assets.refresh(manager)
		r3d.SetOutputMode(.ALBEDO)
		pixel=blend_center_pixel(ctx,&w,manager)
		assert(pixel==expected,fmt.tprintf("control channel %d selects its color: %v != %v",index,pixel,expected))
	}
	// Overlapping channels normalize, and blank masks select the first layer.
	for mix in 0..<2 {
		for control,group in controls {
			color:=rl.BLANK
			if mix==0 && group==0 {color={255,0,255,0}}
			image:=rl.GenImageColor(1,1,color)
			assert(rl.ExportImage(image,strings.clone_to_cstring(control,context.temp_allocator))); rl.UnloadImage(image)
		}
		assets.refresh(manager); pixel=blend_center_pixel(ctx,&w,manager)
		if mix==0 {assert(abs(int(pixel.r)-128)<2 && pixel.g==0 && abs(int(pixel.b)-128)<2,"mask weights normalize across overlapping layers")}
		else {assert(pixel==colors[0],"empty mask falls back to first layer")}
	}
	// Restore the last channel and change its procedural normal map live.
	image:=rl.GenImageColor(1,1,{0,0,0,255})
	assert(rl.ExportImage(image,"build/eight-control-1.png")); rl.UnloadImage(image)
	assets.refresh(manager)
	revision:=ctx.terrains[e].revision
	write_layer_fixture(layers[7].material,colors[7],roughness=0.8,metallic=1,bump=0.2)
	assets.refresh_materials(manager)
	r3d.SetOutputMode(.NORMAL)
	normal_colors:int
	blend_center_pixel(ctx,&w,manager,unique_red=&normal_colors)
	assert(normal_colors>2 && ctx.terrains[e].revision==revision,"eighth-layer normals hot reload without rebuilding terrain")
	r3d.SetOutputMode(.ALBEDO)
	// Invalid material edits retain the packed layer set without a terrain reload.
	packed:=ctx.terrains[e].layer_set.atlases[1].id
	assert(write_fixture(layers[7].material,"invalid")==nil)
	assets.refresh_materials(manager)
	pixel=blend_center_pixel(ctx,&w,manager)
	assert(pixel==colors[7] && ctx.terrains[e].layer_set.atlases[1].id==packed,"invalid eighth material retains set")
	assert(ecs.destroy_entity(&w,e)); render_frame(ctx,&w,manager)
	assert(len(ctx.terrains)==0,"layer set is released when terrain is removed")
	r3d.SetOutputMode(.SCENE)
	fmt.println("PASS eight independent terrain materials, ORM, all eight control channels, live masks and cleanup")
}
