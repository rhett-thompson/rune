package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "rune:ecs"
import "rune:assets"
import bridge "rune:r3d_bridge"
import rl "vendor:raylib"

parse :: proc(text:string) -> json.Value {
	v:json.Value
	assert(json.unmarshal(transmute([]u8)text,&v,allocator=context.temp_allocator)==nil)
	return v
}

main :: proc() {
	profile,ok:=ecs.post_processing_from_json(parse(`{"light_shafts":{"enabled":true,"source":"emitter"}}`))
	assert(ok && profile.light_shafts.samples==32 && profile.light_shafts.radius==0.7)
	data,serialized:=ecs.post_processing_json(profile)
	copy,valid:=ecs.post_processing_from_json(data)
	assert(serialized && valid && copy==profile)
	for text in ([]string{`{"light_shafts":{"enabled":true}}`,`{"light_shafts":{"intensity":-1}}`,`{"light_shafts":{"radius":0}}`,`{"light_shafts":{"source_radius":0}}`,`{"light_shafts":{"samples":7}}`,`{"light_shafts":{"samples":65}}`,`{"light_shafts":{"samples":16.5}}`,`{"light_shafts":{"source":null}}`}) {
		_,accepted:=ecs.post_processing_from_json(parse(text)); assert(!accepted,text)
	}
	registry:=ecs.init_registry(); defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	w:=ecs.init(); defer ecs.destroy(&w)
	post:=ecs.create_entity(&w)
	owned:=strings.clone("emitter")
	profile.light_shafts.source=owned
	assert(ecs.add(&w,&registry,post,profile)); delete(owned)
	stored,_:=ecs.get(&w,post,ecs.PostProcessing); assert(stored.light_shafts.source=="emitter")
	owned=strings.clone("replacement"); stored.light_shafts.source=owned
	assert(ecs.set(&w,post,stored)); delete(owned)
	stored,_=ecs.get(&w,post,ecs.PostProcessing); assert(stored.light_shafts.source=="replacement")
	stored.light_shafts.radius=math.nan_f32(); assert(!ecs.set(&w,post,stored))
	for arg in os.args[1:] {if arg=="--runtime" {validate_runtime()}}
	fmt.println("Light shafts validation passed")
}

sample_frame :: proc(ctx:^bridge.Context,w:^ecs.World,manager:^assets.Asset_Manager,x:i32=205,y:i32=120) -> rl.Color {
	for _ in 0..<3 {
		rl.BeginDrawing(); assert(bridge.draw_scene_ex(ctx,w,manager,{background_color=rl.BLACK})); rl.EndDrawing()
	}
	image:=rl.LoadImageFromScreen(); defer rl.UnloadImage(image)
	return rl.GetImageColor(image,x,y)
}

validate_runtime :: proc() {
	rl.SetConfigFlags({.WINDOW_HIDDEN}); rl.InitWindow(320,240,"Light shafts validation"); defer rl.CloseWindow()
	ctx,ok:=bridge.init(".",320,240); assert(ok); defer bridge.shutdown(&ctx)
	manager:=assets.init("."); defer assets.shutdown(&manager)
	registry:=ecs.init_registry(); defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	w:=ecs.init(); defer ecs.destroy(&w)
	camera:=ecs.create_entity(&w)
	assert(ecs.add(&w,&registry,camera,ecs.Transform{scale={1,1,1}}))
	assert(ecs.add_component(&w,&registry,camera,"Camera3D",parse(`{"active":true,"target":[0,0,-1],"fovy":60}`)))
	source:=ecs.create_entity(&w); ecs.set_entity_metadata(&w,source,"emitter","Emitter","",ecs.Default_Layer_Mask)
	assert(ecs.add(&w,&registry,source,ecs.Transform{position={0,0,-10},scale={1,1,1}}))
	assert(ecs.add(&w,&registry,source,ecs.MeshRenderer{primitive="cube",color={255,255,255,255}}))
	post:=ecs.create_entity(&w)
	p:=ecs.default_post_processing()
	p.light_shafts.enabled=true; p.light_shafts.source="emitter"; p.light_shafts.intensity=1; p.light_shafts.source_radius=1
	assert(ecs.add(&w,&registry,post,p))
	c:=sample_frame(&ctx,&w,&manager); fmt.println("visible source",c)
	assert(c.r>30,"unoccluded emitter must scatter into pixels outside the mesh")
	unblocked:=c
	blocker:=ecs.create_entity(&w)
	assert(ecs.add(&w,&registry,blocker,ecs.Transform{position={0.75,0,-5},scale={0.25,1,0.2}}))
	assert(ecs.add(&w,&registry,blocker,ecs.MeshRenderer{primitive="cube",color={0,0,0,255}}))
	c=sample_frame(&ctx,&w,&manager); fmt.println("radial occluder",c)
	assert(c.r>5 && int(c.r)<int(unblocked.r)-3,"intervening geometry must dim rays away from the occluder's silhouette")
	c=sample_frame(&ctx,&w,&manager,191,120); fmt.println("scattering across foreground",c)
	assert(c.r>10,"scattering must cross a foreground surface instead of being clipped to sky pixels")
	// Silhouettes beyond the finite source still mask screen-space scattering.
	assert(ecs.set_transform(&w,blocker,ecs.Transform{position={2.25,0,-15},scale={0.75,3,0.2}}))
	c=sample_frame(&ctx,&w,&manager); fmt.println("distant radial occluder",c)
	assert(int(c.r)<int(unblocked.r)-3,"background architecture must produce radial shadow wedges")
	// A wall filling the viewport leaves no scattering mask to smear.
	assert(ecs.set_transform(&w,blocker,ecs.Transform{position={0,0,-5},scale={20,20,0.2}}))
	c=sample_frame(&ctx,&w,&manager); fmt.println("blocked source",c)
	assert(c.r<5,"a hidden emitter must not leak shafts")
	ecs.destroy_entity(&w,blocker)
	assert(ecs.set_transform(&w,source,ecs.Transform{position={0,0,10},scale={1,1,1}}))
	assert(sample_frame(&ctx,&w,&manager).r<5,"source behind camera must disable shafts")
	assert(ecs.set_transform(&w,source,ecs.Transform{position={100,0,-10},scale={1,1,1}}))
	assert(sample_frame(&ctx,&w,&manager).r<5,"source far outside view must disable shafts")
	assert(ecs.set_transform(&w,source,ecs.Transform{position={0,0,-10},scale={1,1,1}}))
	assert(ecs.set_enabled(&w,source,false))
	assert(sample_frame(&ctx,&w,&manager).r<5)
	assert(ecs.set_enabled(&w,source,true))
	p.light_shafts.enabled=false; assert(ecs.set(&w,post,p))
	assert(sample_frame(&ctx,&w,&manager).r<5,"profile toggle must immediately remove scattering")
	assert(len(manager.diagnostics.reported)==0)
}
