package main

import "core:fmt"
import "core:math/linalg"
import "core:os"
import "rune:assets"
import "rune:ecs"
import "rune:geometry"
import bridge "rune:r3d_bridge"
import rl "vendor:raylib"

main :: proc() {
	// Projection must retain two dimensions on walls and a consistent tangent
	// frame on opposite faces; otherwise normal maps invert or smear vertically.
	for n in ([6][3]f32{{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}}) {
		uv,t:=bridge.static_mesh_projection({4,8,12},n)
		tangent:=[3]f32{t[0],t[1],t[2]}
		bitangent:=linalg.cross(n,tangent)*t[3]
		u2,_:=bridge.static_mesh_projection([3]f32{4,8,12}+tangent*4,n)
		v2,_:=bridge.static_mesh_projection([3]f32{4,8,12}+bitangent*4,n)
		assert(u2-uv==[2]f32{1,0} && v2-uv==[2]f32{0,1})
	}
	for arg in os.args[1:] {if arg=="--runtime" {validate_runtime()}}
	fmt.println("Static mesh material validation passed")
}

sample :: proc(ctx:^bridge.Context,w:^ecs.World,manager:^assets.Asset_Manager) -> rl.Color {
	for _ in 0..<3 {
		rl.BeginDrawing(); assert(bridge.draw_scene_ex(ctx,w,manager,{background_color=rl.BLACK})); rl.EndDrawing()
	}
	image:=rl.LoadImageFromScreen(); defer rl.UnloadImage(image)
	return rl.GetImageColor(image,160,120)
}

validate_runtime :: proc() {
	rl.SetConfigFlags({.WINDOW_HIDDEN}); rl.InitWindow(320,240,"Static mesh material validation"); defer rl.CloseWindow()
	ctx,ok:=bridge.init("build",320,240); assert(ok); defer bridge.shutdown(&ctx)
	manager:=assets.init("build"); defer assets.shutdown(&manager)
	registry:=ecs.init_registry(); defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	w:=ecs.init(); defer ecs.destroy(&w)
	camera:=ecs.create_entity(&w)
	assert(ecs.add(&w,&registry,camera,ecs.Transform{scale={1,1,1}}))
	assert(ecs.add(&w,&registry,camera,ecs.Camera3D{active=true,target={0,0,-1},up={0,1,0},fovy=60}))
	volume:=geometry.Volume{size={1,1,1},spacing=2,origin={-1,-1,-6},cells=make([]u8,1)}
	defer delete(volume.cells)
	volume.cells[0]=1
	colors:=[2][4]u8{{},{255,255,255,255}}
	mesh,valid:=geometry.surface(volume,colors[:]); assert(valid); defer geometry.destroy_mesh(&mesh)
	entity:=ecs.create_entity(&w)
	assert(ecs.add(&w,&registry,entity,ecs.Transform{scale={1,1,1}}))
	assert(ecs.set_static_mesh(&w,entity,mesh))
	path :: "static-runtime.material.json"
	full_path :: "build/static-runtime.material.json"
	defer os.remove(full_path)
	assert(os.write_entire_file(full_path,`{"lighting":false,"base_color":[220,40,20,255]}`)==nil)
	renderer:=ecs.MeshRenderer{primitive="static",material=path,color={255,255,255,255},shadows=false}
	assert(ecs.add(&w,&registry,entity,renderer))
	red:=sample(&ctx,&w,&manager)
	assert(red.r>red.g*2 && red.r>red.b*2,"runtime mesh must use its material without a duplicate primitive")
	assert(len(ctx.static_meshes)==1 && len(ctx.r3d_materials)==1)
	// As with primitive renderers, color supplies the fallback when no material
	// is selected. This must work without replacing installed geometry.
	ambient:=ecs.create_entity(&w)
	assert(ecs.add(&w,&registry,ambient,ecs.AmbientLight{color={255,255,255,255},intensity=1}))
	renderer.material=""; renderer.color={20,220,20,255}; assert(ecs.set(&w,entity,renderer))
	green:=sample(&ctx,&w,&manager)
	assert(int(green.g)>int(green.r)*2 && int(green.g)>int(green.b)*2,"renderer fallback color must style the mesh")
	// A material reload also reuses the installed mesh and material cache entry.
	assert(os.write_entire_file(full_path,`{"lighting":false,"base_color":[20,40,220,255]}`)==nil)
	stale:=manager.materials[path]; stale.modified_time=-2; manager.materials[path]=stale
	assets.refresh_materials(&manager)
	renderer.material=path; renderer.color={255,255,255,255}; assert(ecs.set(&w,entity,renderer))
	blue:=sample(&ctx,&w,&manager)
	assert(blue.b>blue.r*2 && blue.b>blue.g*2,"static mesh material reload must update pixels")
	assert(len(ctx.static_meshes)==1 && len(ctx.r3d_materials)==1)
	hit,found:=ecs.physics_3d_raycast(&w,{0,0,0},{0,0,-10})
	assert(found && hit.entity==entity,"material styling must preserve static collision")
	assert(ecs.set_enabled(&w,entity,false)); assert(sample(&ctx,&w,&manager).r<5)
	assert(ecs.destroy_entity(&w,entity)); sample(&ctx,&w,&manager)
	assert(len(ctx.static_meshes)==0,"entity destruction must release the GPU mesh")
	assert(len(manager.diagnostics.reported)==0)
}
