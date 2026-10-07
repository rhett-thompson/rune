package main

import "core:fmt"
import "core:os"
import "rune:assets"
import "rune:ecs"
import "rune:gizmos"
import "rune:navigation"
import rl "vendor:raylib"

validate_navmesh_gizmos :: proc() {
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(240, 240, "Navigation gizmos validation")
	defer rl.CloseWindow()
	mesh, error := navigation.build_mesh_3d({version=1, agent_radius=0.4, agent_height=2,
		vertices=[][3]f32{{-2,0,-2},{-2,0,2},{2,0,2},{2,0,-2}},
		triangles=[][3]i32{{0,1,2},{0,2,3}}})
	assert(error == "", error)
	defer navigation.destroy_mesh_3d(&mesh)
	path := "build/navigation-gizmos-test.navmesh.json"
	assert(navigation.write_mesh_3d(path, &mesh) == "")
	defer os.remove(path)
	manager := assets.init(".")
	defer assets.shutdown(&manager)
	r := ecs.init_registry()
	defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	w := ecs.init()
	defer ecs.destroy(&w)
	nav := ecs.create_entity(&w)
	assert(ecs.set_entity_metadata(&w, nav, "navigation", "Navigation", "", ecs.Default_Layer_Mask))
	assert(ecs.add(&w, &r, nav, ecs.NavMesh3D{asset=path}))
	ecs.sync_navigation_3d(&w, &manager)
	assert(ecs.set_navigation_triangle_blocked_3d(&w, nav, 1, true))
	view := ecs.create_entity(&w)
	assert(ecs.add(&w, &r, view, ecs.Transform{position={0,10,0},scale={1,1,1}}))
	assert(ecs.add(&w, &r, view, ecs.Camera3D{target={0,0,0},up={0,0,-1},fovy=6,active=true,projection=.orthographic}))
	camera := rl.Camera3D{position={0,10,0},target={0,0,0},up={0,0,-1},fovy=6,projection=.ORTHOGRAPHIC}
	left := rl.GetWorldToScreen(mesh.triangles[0].center, camera)
	right := rl.GetWorldToScreen(mesh.triangles[1].center, camera)
	target := rl.LoadRenderTexture(240,240)
	defer rl.UnloadRenderTexture(target)
	background := rl.Color{80,80,80,255}
	assert(os.make_directory_all("build/captures") == nil)
	for pass in 0..<5 {
		settings := gizmos.Settings{navmeshes=true,navmesh_entity="navigation"}
		if pass == 0 {settings.navmeshes=false}
		if pass == 2 {settings.navmesh_entity="other"}
		if pass == 3 {assert(ecs.set_enabled(&w, nav, false))}
		if pass == 4 {assert(ecs.set_enabled(&w, nav, true));settings.navmesh_entity=""}
		rl.BeginTextureMode(target)
		rl.ClearBackground(background)
		gizmos.draw_scene(&w, settings)
		rl.EndTextureMode()
		picture := rl.LoadImageFromTexture(target.texture)
		rl.ImageFlipVertical(&picture)
		cyan := rl.GetImageColor(picture, i32(left.x), i32(left.y))
		red := rl.GetImageColor(picture, i32(right.x), i32(right.y))
		if pass == 1 || pass == 4 {
			assert(cyan.r < background.r && cyan.g > background.g && cyan.b > background.b, "walkable fill is translucent cyan with the F3 overlay disabled")
			assert(red.r > background.r && red.g < background.g && red.b < background.b, "runtime blocked fill is red")
			assert(rl.ExportImage(picture, "build/captures/navigation-gizmos-validation.png"))
		} else {
			assert(cyan == background && red == background, "off, filtered and disabled surfaces are hidden")
		}
		rl.UnloadImage(picture)
	}
	fmt.println("Navigation gizmos validation passed: active camera, translucent fill, blocked colors, filtering and activation")
}
