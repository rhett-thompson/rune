package main

import "core:fmt"
import "core:os"
import "core:encoding/json"
import "rune:assets"
import "rune:ecs"
import bridge "rune:r3d_bridge"
import rl "vendor:raylib"

parse :: proc(text:string) -> json.Value {
	v:json.Value
	assert(json.unmarshal(transmute([]u8)text,&v,allocator=context.temp_allocator)==nil)
	return v
}

main :: proc() {
	v,ok:=ecs.cloud_volume_from_json(parse(`{}`))
	assert(ok && v==ecs.default_cloud_volume())
	for text in ([]string{`null`,`{"steps":7}`,`{"steps":97}`,`{"steps":32.5}`,`{"density":-1}`,`{"noise_scale":0}`,`{"coverage":1.1}`,`{"coverage":null}`,`{"color":[256,0,0,255]}`,`{"noise_offset":[0,0]}`,`{"unknown":true}`}) {
		_,valid:=ecs.cloud_volume_from_json(parse(text)); assert(!valid,text)
	}
	registry:=ecs.init_registry(); defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	w:=ecs.init(); defer ecs.destroy(&w)
	entity:=ecs.create_entity(&w)
	assert(ecs.add_component(&w,&registry,entity,"CloudVolume",parse(`{"coverage":0.7,"steps":48}`)))
	v,ok=ecs.get(&w,entity,ecs.CloudVolume)
	assert(ok && v.coverage==0.7 && v.steps==48 && v.density==0.035)
	invalid:=v; invalid.steps=0
	assert(!ecs.set(&w,entity,invalid))
	unchanged,_:=ecs.get(&w,entity,ecs.CloudVolume); assert(unchanged==v)
	snapshot,found:=ecs.get_component(&w,entity,"CloudVolume"); assert(found)
	roundtrip,valid:=ecs.cloud_volume_from_json(snapshot); assert(valid && roundtrip==v)
	for arg in os.args[1:] {if arg=="--runtime" {validate_runtime()}}
	fmt.println("Cloud volume validation passed")
}

center_pixel :: proc(ctx:^bridge.Context,w:^ecs.World,manager:^assets.Asset_Manager) -> rl.Color {
	for _ in 0..<3 {
		rl.BeginDrawing()
		assert(bridge.draw_scene_ex(ctx,w,manager,{background_color=rl.BLACK}))
		rl.EndDrawing()
	}
	image:=rl.LoadImageFromScreen(); defer rl.UnloadImage(image)
	return rl.GetImageColor(image,160,120)
}

validate_runtime :: proc() {
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(320,240,"Cloud volume validation"); defer rl.CloseWindow()
	ctx,ok:=bridge.init(".",320,240); assert(ok); defer bridge.shutdown(&ctx)
	manager:=assets.init("."); defer assets.shutdown(&manager)
	registry:=ecs.init_registry(); defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	w:=ecs.init(); defer ecs.destroy(&w)
	camera:=ecs.create_entity(&w)
	assert(ecs.add_component(&w,&registry,camera,"Transform",parse(`{"position":[0,0,0]}`)))
	assert(ecs.add_component(&w,&registry,camera,"Camera3D",parse(`{"active":true,"target":[0,0,-1],"fovy":60}`)))
	cloud:=ecs.create_entity(&w)
	assert(ecs.add(&w,&registry,cloud,ecs.Transform{position={0,0,-6},scale={4,3,4}}))
	v:=ecs.default_cloud_volume(); v.color={255,255,255,255}; v.shadow_color=v.color; v.density=1; v.coverage=1
	assert(ecs.add(&w,&registry,cloud,v))
	p:=center_pixel(&ctx,&w,&manager); fmt.println("unobstructed",p)
	assert(p.r>150,"ray marching must produce opacity inside the ellipsoid")
	blocker:=ecs.create_entity(&w)
	assert(ecs.add(&w,&registry,blocker,ecs.Transform{position={0,0,-2},scale={3,3,0.2}}))
	assert(ecs.add(&w,&registry,blocker,ecs.MeshRenderer{primitive="cube",color={0,0,0,255}}))
	p=center_pixel(&ctx,&w,&manager); fmt.println("foreground",p)
	assert(p.r<5,"opaque foreground must completely occlude clouds")
	assert(ecs.set_transform(&w,blocker,ecs.Transform{position={0,0,-6},scale={3,3,0.2}}))
	p=center_pixel(&ctx,&w,&manager); fmt.println("embedded",p)
	assert(p.r>80,"clouds in front of an embedded opaque object must remain visible")
	ecs.destroy_entity(&w,blocker)
	assert(ecs.set_transform(&w,camera,ecs.Transform{position={0,0,-6},scale={1,1,1}}))
	cam,_:=ecs.get_camera_3d(&w,camera); cam.target={0,0,-7}; assert(ecs.set_camera_3d(&w,camera,cam))
	p=center_pixel(&ctx,&w,&manager); fmt.println("inside",p)
	assert(p.r>80,"camera inside a volume must see participating medium")
	v.density=0; assert(ecs.set(&w,cloud,v))
	assert(center_pixel(&ctx,&w,&manager).r<5,"zero density must render empty space")
	assert(ecs.remove_component(&w,cloud,"CloudVolume"))
	_ = center_pixel(&ctx,&w,&manager)
	assert(len(ctx.cloud_volumes.aliases)==0,"removing a volume must release its shader alias")
	assert(len(manager.diagnostics.reported)==0)
}
