package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:encoding/json"
import "rune:assets"
import "rune:ecs"
import bridge "rune:r3d_bridge"
import rl "vendor:raylib"

parse :: proc(text: string) -> json.Value {
	value: json.Value
	assert(json.unmarshal(transmute([]u8)text,&value,allocator=context.temp_allocator)==nil)
	return value
}

main :: proc() {
	path :: "build/billboard-validation.material.json"
	defer os.remove(path)
	for name in ([]string{"disabled","front","y_axis","invalid"}) {
		text, _ := strings.concatenate({`{"billboard":"`,name,`"}`},context.temp_allocator)
		assert(os.write_entire_file(path,text)==nil)
		material,ok := assets.load_material_data(path)
		assert(ok == (name != "invalid"))
		if !ok {continue}
		assert(material.billboard == name)
		copy := assets.clone_material_data(material)
		assets.destroy_material_data(&material)
		assert(copy.billboard == name,"billboard strings have owned cache lifetimes")
		disabled := copy
		disabled.billboard = ""
		assert(assets.material_data_signature(copy) != assets.material_data_signature(disabled),"billboard changes invalidate the renderer cache")
		assets.destroy_material_data(&copy)
	}
	assert(os.write_entire_file(path,`{"billboard":"front","lighting":false,"base_color":[255,255,255,255],"transparency":"alpha"}`)==nil)
	for arg in os.args[1:] {if arg=="--runtime" {validate_runtime(path)}}
	fmt.println("Billboard validation passed")
}

validate_runtime :: proc(path: string) {
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(160,120,"Billboard validation")
	defer rl.CloseWindow()
	ctx,ok := bridge.init(".",160,120)
	assert(ok)
	defer bridge.shutdown(&ctx)
	manager := assets.init(".")
	defer assets.shutdown(&manager)
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	w := ecs.init()
	defer ecs.destroy(&w)
	camera := ecs.create_entity(&w)
	assert(ecs.add_component(&w,&registry,camera,"Transform",parse(`{"position":[0,0,5]}`)))
	assert(ecs.add_component(&w,&registry,camera,"Camera3D",parse(`{"active":true,"target":[0,0,0],"fovy":60}`)))
	card := ecs.create_entity(&w)
	assert(ecs.add(&w,&registry,card,ecs.Transform{scale={2,1,1}}))
	assert(ecs.add(&w,&registry,card,ecs.MeshRenderer{primitive="quad",color={255,255,255,255},material=path}))
	for position in ([3][3]f32{{0,0,5},{5,0,0},{0,4,3}}) {
		assert(ecs.set_transform(&w,camera,ecs.Transform{position=position,scale={1,1,1}}))
		for _ in 0..<3 {
			rl.BeginDrawing()
			assert(bridge.draw_scene_ex(&ctx,&w,&manager,{background_color=rl.BLACK}))
			rl.EndDrawing()
		}
		image := rl.LoadImageFromScreen()
		center := rl.GetImageColor(image,80,60)
		wide := rl.GetImageColor(image,94,60)
		outside := rl.GetImageColor(image,80,82)
		rl.UnloadImage(image)
		assert(center.r>240 && wide.r>240 && outside.r<5,"the XY quad must face each camera and retain nonuniform dimensions")
	}
	assert(len(manager.diagnostics.reported)==0)
}
