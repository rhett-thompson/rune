package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "rune:assets"
import "rune:console"
import rune "rune:core"
import "rune:ecs"
import "rune:render"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

// Render actual geometry before querying it; this catches mismatches between
// camera/canvas presentation and the CPU picker that headless tests cannot.
validate_debug_picking_view :: proc(registry: ^ecs.Component_Registry) {
	rl.SetConfigFlags({.WINDOW_HIDDEN, .WINDOW_HIGHDPI, .MSAA_4X_HINT})
	rl.InitWindow(1000, 800, "Rune console scene picking validation")
	defer rl.CloseWindow()
	rl.SetExitKey(rl.KeyboardKey(0))
	validate_console_cursor()
	assert(os.make_directory_all("build/captures") == nil || os.exists("build/captures"))
	world := ecs.init()
	defer ecs.destroy(&world)
	game := rune.Engine{console = console.init(), registry = registry^, assets = assets.init(".")}
	defer assets.shutdown(&game.assets)
	defer console.destroy_renderer(&game.console)
	defer render.destroy_canvas(&game.canvas)
	rune.register_debug_commands(&game.console)
	rune.bind_debug_console(&game, &world)
	game.console.is_open = true
	game.debug.paused = true
	assert(console.insert_text(&game.console, "unfinished draft"))
	game.project.render_2d = {policy = .fit, width = 400, height = 400}
	camera_2d := ecs.create_entity(&world)
	assert(ecs.add_component(&world, registry, camera_2d, "Transform", parse(`{}`)))
	assert(ecs.add_component(&world, registry, camera_2d, "Camera2D", parse(`{"active":true}`)))
	shape := ecs.create_entity(&world)
	assert(ecs.set_entity_metadata(&world, shape, "picked shape", "Teal square", "", ecs.Default_Layer_Mask))
	assert(ecs.add_component(&world, registry, shape, "Transform", parse(`{"position":[280,280,0]}`)))
	assert(ecs.add_component(&world, registry, shape, "ShapeRenderer2D", parse(`{"shape":"rectangle","size":[40,40],"origin":[0,0],"color":[46,190,135,255]}`)))
	screen := [2]f32{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
	framebuffer := [2]f32{f32(rl.GetRenderWidth()), f32(rl.GetRenderHeight())}
	pick_point := [2]f32{700, 600}
	draw_picking_view(&game, &world, nil)
	before := rl.LoadImageFromScreen()
	assert(picking_pixel(before, pick_point, screen) == rl.Color{46,190,135,255}, "the test point must touch the rendered 2D shape")
	rl.UnloadImage(before)
	assert(rune.debug_pick_scene(&game, pick_point, screen, framebuffer))
	assert(game.console.result_data.(json.Object)["entity"].(json.Object)["id"].(json.String) == "picked shape")
	assert(string(game.console.input[:game.console.input_len]) == "unfinished draft" && game.console.history_count == 0)
	validate_selection_marker(&game,&world,nil,pick_point,{46,190,135,255},"build/captures/console-selection-clean-2d.png")
	snapshot_picking_view("build/captures/console-object-picking-2d.png")
	sequence := game.console.log_sequence
	assert(!rune.debug_pick_scene(&game, {50,600}, screen, framebuffer), "letterbox clicks must be ignored")
	assert(!rune.debug_pick_scene(&game, {700,200}, screen, framebuffer), "console clicks must be ignored")
	assert(game.console.log_sequence == sequence)

	assert(ecs.set_enabled(&world, camera_2d, false))
	game.project.render_2d = {policy = .native}
	camera_3d := ecs.create_entity(&world)
	assert(ecs.add_component(&world, registry, camera_3d, "Transform", parse(`{"position":[0,0,10]}`)))
	assert(ecs.add_component(&world, registry, camera_3d, "Camera3D", parse(`{"active":true,"target":[0,0,0],"up":[0,1,0],"fovy":60}`)))
	cube := ecs.create_entity(&world)
	assert(ecs.set_entity_metadata(&world, cube, "picked_cube", "Orange cube", "", ecs.Default_Layer_Mask))
	assert(ecs.add_component(&world, registry, cube, "Transform", parse(`{"position":[0,-2.5,0],"scale":[2,1.5,1]}`)))
	assert(ecs.add_component(&world, registry, cube, "MeshRenderer", parse(`{"primitive":"cube"}`)))
	for projection in ([2]ecs.Camera_Projection{.perspective, .orthographic}) {
		component, _ := ecs.get_camera_3d(&world, camera_3d)
		component.projection = projection
		component.fovy = 60 if projection == .perspective else 10
		assert(ecs.set_camera_3d(&world, camera_3d, component))
		camera := rl.Camera3D{position = {0,0,10}, target = {}, up = {0,1,0},
			fovy = component.fovy, projection = rl.CameraProjection(projection)}
		point := rl.GetWorldToScreenEx({0,-2.5,0}, camera, i32(screen[0]), i32(screen[1]))
		draw_picking_view(&game, &world, &camera)
		image := rl.LoadImageFromScreen()
		assert(picking_pixel(image, point, screen) == rl.ORANGE, "the test point must touch the rendered 3D cube")
		rl.UnloadImage(image)
		origin, translation, valid := rune.debug_pick_camera_ray(camera, point, screen,
			f32(rlgl.GetCullDistanceNear()), f32(rlgl.GetCullDistanceFar()))
		assert(valid)
		reference := rl.GetScreenToWorldRayEx(point, camera, i32(screen[0]), i32(screen[1]))
		assert(rl.Vector3DotProduct(rl.Vector3Normalize(translation), reference.direction) > 0.99999)
		difference := origin - reference.position
		assert(rl.Vector3Length(rl.Vector3CrossProduct(difference, reference.direction)) < 0.001,
			"CPU picking must follow the same screen ray as raylib drawing")
		assert(rune.debug_pick_scene(&game, point, screen, framebuffer))
		assert(game.console.result_data.(json.Object)["entity"].(json.Object)["id"].(json.String) == "picked_cube")
		validate_selection_marker(&game,&world,&camera,point,rl.ORANGE,
			"build/captures/console-selection-clean-3d.png" if projection==.perspective else "build/captures/console-selection-clean-orthographic.png")
		snapshot_picking_view("build/captures/console-object-picking-3d.png" if projection == .perspective else "build/captures/console-object-picking-orthographic.png")
	}
	fmt.println("Console scene picking and selection: rendered 2D canvas, perspective/orthographic 3D, and clean captures passed")
}

validate_selection_marker :: proc(game: ^rune.Engine, world: ^ecs.World, camera: ^rl.Camera3D, center: [2]f32, color: rl.Color, capture_path: string) {
	screen := [2]f32{f32(rl.GetScreenWidth()),f32(rl.GetScreenHeight())}
	framebuffer := [2]f32{f32(rl.GetRenderWidth()),f32(rl.GetRenderHeight())}
	bounds,visible := rune.debug_selection_bounds(game,screen,framebuffer)
	assert(visible && rl.CheckCollisionPointRec(center,bounds),"selection must track the rendered object")
	assert(console.execute(&game.console,fmt.tprintf("capture %s",capture_path)))
	draw_picking_view(game,world,camera)
	path_c,_ := strings.clone_to_cstring(capture_path,context.temp_allocator)
	clean := rl.LoadImage(path_c); defer rl.UnloadImage(clean)
	marked := rl.LoadImageFromScreen(); defer rl.UnloadImage(marked)
	assert(clean.data!=nil && clean.width==marked.width && clean.height==marked.height)
	assert(picking_pixel(marked,center,screen)==color && picking_pixel(clean,center,screen)==color,
		"the object surface must retain its rendered color")
	panel := console.view_layout(screen[0],screen[1]).panel
	clean_markers,visible_markers := 0,0
	for y:i32=0; y<marked.height; y+=1 {
		logical_y := f32(y)*screen[1]/f32(marked.height)
		if logical_y<=panel.y+panel.height+6 {continue}
		for x:i32=0; x<marked.width; x+=1 {
			logical_x := f32(x)*screen[0]/f32(marked.width)
			a,b := rl.GetImageColor(clean,x,y),rl.GetImageColor(marked,x,y)
			if a==rune.Debug_Selection_Color {clean_markers+=1}
			if b==rune.Debug_Selection_Color {visible_markers+=1}
			near_bounds := logical_x>=bounds.x-8 && logical_x<=bounds.x+bounds.width+8 &&
				logical_y>=bounds.y-8 && logical_y<=bounds.y+bounds.height+8
			if !near_bounds {assert(a==b,"the selection overlay cannot alter scene pixels away from its brackets")}
		}
	}
	assert(clean_markers==0 && visible_markers>0,"selection brackets are visible but excluded from the capture command")
}

picking_pixel :: proc(image: rl.Image, point, screen: [2]f32) -> rl.Color {
	return rl.GetImageColor(image, i32(math.floor(point[0] * f32(image.width) / screen[0])),
		i32(math.floor(point[1] * f32(image.height) / screen[1])))
}

draw_picking_view :: proc(game: ^rune.Engine, world: ^ecs.World, camera: ^rl.Camera3D) {
	for _ in 0..<3 {
		rl.BeginDrawing()
		assert(render.begin_canvas(&game.canvas, game.project.render_2d))
		rl.ClearBackground({8,12,18,255})
		if camera == nil {
			assert(render.draw_scene_2d(world, &game.assets))
		} else {
			rl.BeginMode3D(camera^)
			rl.DrawCubeV({0,-2.5,0}, {2,1.5,1}, rl.ORANGE)
			rl.EndMode3D()
		}
		render.end_canvas(&game.canvas)
		console.finish_frame(&game.console)
		rune.draw_debug_selection(game)
		console.draw(&game.console)
		rl.EndDrawing()
	}
}

snapshot_picking_view :: proc(path: cstring) {
	image := rl.LoadImageFromScreen()
	defer rl.UnloadImage(image)
	assert(rl.ExportImage(image, path))
}
