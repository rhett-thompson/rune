package core

import "core:fmt"
import "core:math"
import "rune:console"
import "rune:ecs"
import "rune:render"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

// Inspect an object under a native logical screen point while the console is
// open. Called on a left-button press, outside the console panel. Geometry and
// camera queries borrow the currently bound World; selection retains only a
// generation-bound handle and is revalidated when drawing its debug overlay.
// Pending console replies keep exclusive ownership of their logs and results.
debug_pick_scene :: proc(engine: ^Engine, screen_point, screen_size, framebuffer_size: [2]f32) -> bool {
	when Player_Build {return false}
	if engine == nil || engine.exit_requested || !engine.console.is_open ||
	   engine.debug.world == nil || engine.console.defer_reply || engine.console.remote.result_len > 0 {return false}
	for vector in ([3][2]f32{screen_point, screen_size, framebuffer_size}) {
		for value in vector {if math.is_nan(value) || math.is_inf(value) {return false}}
	}
	if screen_size[0] <= 0 || screen_size[1] <= 0 || framebuffer_size[0] <= 0 || framebuffer_size[1] <= 0 {return false}
	panel := console.view_layout(screen_size[0], screen_size[1]).panel
	if rl.CheckCollisionPointRec(screen_point, panel) {return false}
	point, inside := render.screen_to_canvas(engine.project.render_2d, screen_size, framebuffer_size, screen_point)
	if !inside {return false}
	world := engine.debug.world
	entity: ecs.Entity
	dimension: Debug_Pick_Dimension
	found := false
	camera_entity, component, active := ecs.active_camera_3d(world)
	_, camera_has_pose := ecs.get_transform(world, camera_entity)
	if active && camera_has_pose {
		pose := ecs.world_transform_3d(world, camera_entity)
		camera := rl.Camera3D{position = pose.position, target = component.target, up = component.up,
			fovy = component.fovy, projection = rl.CameraProjection(component.projection)}
		near, far := f32(0.01), f32(1000)
		if rl.IsWindowReady() {near, far = f32(rlgl.GetCullDistanceNear()), f32(rlgl.GetCullDistanceFar())}
		origin, translation, valid := debug_pick_camera_ray(camera, point,
			render.canvas_dimensions(engine.project.render_2d, screen_size), near, far)
		if valid {
			hit, picked := render.scene_pick_3d(world, origin, translation, &engine.assets)
			if picked {entity, found, dimension = hit.entity, true, .Three_D}
		}
	}
	if !found {
		if camera_entity, component, active := ecs.active_camera_2d(world); active {
			if pose, has_pose := ecs.get_transform(world, camera_entity); has_pose && component.zoom != 0 {
				camera := rl.Camera2D{offset = component.offset, target = {pose.position[0], pose.position[1]},
					rotation = component.rotation, zoom = component.zoom}
				world_point := rl.GetScreenToWorld2D(point, camera)
				entity, found = render.scene_pick_2d(world, &engine.assets, world_point)
				if found {dimension = .Two_D}
			}
		}
	}
	if !found {clear_debug_selection(engine); return false}
	if !inspect_debug_entity(&engine.console, world, entity) {return false}
	engine.debug.picked_entity = entity
	engine.debug.picked_dimension = dimension
	summary := entity_summary(world, entity)
	name := fmt.tprintf(" (%s)", summary.name) if summary.name != "" else ""
	console.info(&engine.console, fmt.tprintf("Picked %s%s - %d components. Details above.", summary.id, name, len(summary.components)))
	engine.console.scroll_offset = 0
	engine.console.scroll_anchor_sequence = 0
	return true
}

// A CPU-only camera ray clipped to axial near/far planes. Perspective corner
// rays need a longer segment than far-near; orthographic rays start at their
// own point on the near plane. Dimensions are those of the presented canvas.
debug_pick_camera_ray :: proc(camera: rl.Camera3D, point, viewport: [2]f32, near, far: f32) -> (origin, translation: [3]f32, valid: bool) {
	for vector in ([3][3]f32{camera.position, camera.target, camera.up}) {
		for value in vector {if math.is_nan(value) || math.is_inf(value) {return}}
	}
	for value in ([7]f32{point[0], point[1], viewport[0], viewport[1], camera.fovy, near, far}) {
		if math.is_nan(value) || math.is_inf(value) {return}
	}
	if viewport[0] <= 0 || viewport[1] <= 0 || near < 0 || far <= near || camera.fovy <= 0 {return}
	forward := camera.target - camera.position
	length := rl.Vector3Length(forward)
	if length <= 0 {return}
	forward /= length
	right := rl.Vector3CrossProduct(forward, camera.up)
	length = rl.Vector3Length(right)
	if length <= 0 {return}
	right /= length
	up := rl.Vector3CrossProduct(right, forward)
	x, y := point[0] * 2 / viewport[0] - 1, 1 - point[1] * 2 / viewport[1]
	aspect := viewport[0] / viewport[1]
	switch camera.projection {
	case .PERSPECTIVE:
		if camera.fovy >= 180 {return}
		height := math.tan(camera.fovy * (math.PI / 360))
		direction := rl.Vector3Normalize(forward + right * (x * aspect * height) + up * (y * height))
		depth := rl.Vector3DotProduct(direction, forward)
		if depth <= 0 {return}
		origin = camera.position + direction * (near / depth)
		translation = direction * ((far - near) / depth)
	case .ORTHOGRAPHIC:
		origin = camera.position + right * (x * aspect * camera.fovy / 2) + up * (y * camera.fovy / 2) + forward * near
		translation = forward * (far - near)
	case: return
	}
	return origin, translation, true
}
