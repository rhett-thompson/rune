package main

import "core:fmt"
import "core:math"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import "rune:render"
import rl "vendor:raylib"

Player_Speed : f32 : 6
Camera_Height : f32 : 1.5
Mouse_Orbit_Speed : f32 : 0.25

world: ecs.World
player: ecs.Entity
follow_camera: ecs.Entity
// Face the landmark side of the playground on startup.
camera_yaw: f32 = 180
camera_pitch: f32 = 22
camera_distance: f32 = 7

scene_view := render.Scene3D_Settings{grid_slices = 30, grid_spacing = 1, draw_colliders = true}

clamp :: proc(value, minimum, maximum: f32) -> f32 {
	if value < minimum { return minimum }
	if value > maximum { return maximum }
	return value
}

update_follow_camera :: proc() {
	player_transform, has_player := ecs.get_transform(&world, player)
	camera_transform, has_camera_transform := ecs.get_transform(&world, follow_camera)
	camera, has_camera := ecs.get_camera_3d(&world, follow_camera)
	if !has_player || !has_camera_transform || !has_camera { return }

	yaw := camera_yaw * f32(math.PI / 180)
	pitch := camera_pitch * f32(math.PI / 180)
	forward := [3]f32{f32(math.sin(f64(yaw))), 0, f32(math.cos(f64(yaw)))}
	horizontal_distance := camera_distance * f32(math.cos(f64(pitch)))
	camera_transform.position = {
		player_transform.position[0] - forward[0] * horizontal_distance,
		player_transform.position[1] + Camera_Height + camera_distance * f32(math.sin(f64(pitch))),
		player_transform.position[2] - forward[2] * horizontal_distance,
	}
	camera.target = {player_transform.position[0], player_transform.position[1] + 0.4, player_transform.position[2]}
	ecs.set_transform(&world, follow_camera, camera_transform)
	ecs.set_camera_3d(&world, follow_camera, camera)
}

on_update :: proc(game: ^rune.Engine) {
	controls := rune.input_state(game)
	camera_distance = clamp(camera_distance - input.axis(controls, "zoom"), 3, 12)
	orbit_camera := input.is_down(controls, "orbit_camera")
	orbit_with_character := input.is_down(controls, "orbit_with_character")
	if orbit_camera || orbit_with_character {
		camera_yaw -= input.axis(controls, "look_x") * Mouse_Orbit_Speed
		camera_pitch += input.axis(controls, "look_y") * Mouse_Orbit_Speed
		camera_pitch = clamp(camera_pitch, 8, 70)
	}

	yaw := camera_yaw * f32(math.PI / 180)
	forward := [3]f32{f32(math.sin(f64(yaw))), 0, f32(math.cos(f64(yaw)))}
	// Raylib's view basis points screen-right opposite this camera-forward
	// vector, so use the matching sign for A/D screen-space strafing.
	right := [3]f32{-forward[2], 0, forward[0]}
	move_x := input.axis(controls, "move_x")
	move_z := input.axis(controls, "move_z")
	horizontal := [2]f32{}
	if move_x != 0 || move_z != 0 {
		length := f32(math.sqrt(f64(move_x * move_x + move_z * move_z)))
		move_x /= length
		move_z /= length
		horizontal = {
			(forward[0] * move_z + right[0] * move_x) * Player_Speed * game.delta_time,
			(forward[2] * move_z + right[2] * move_x) * Player_Speed * game.delta_time,
		}
	}
	ecs.move_character(&world, player, horizontal, input.pressed(controls, "jump"), game.delta_time)

	transform, found := ecs.get_transform(&world, player)
	if !found { return }
	// Left-click only changes the camera. Right-click keeps the character aligned
	// with the camera yaw; the white front marker makes that rotation visible.
	if orbit_with_character { transform.rotation[1] = camera_yaw }
	ecs.set_transform(&world, player, transform)

	update_follow_camera()
}

on_draw :: proc(game: ^rune.Engine) {
	if !render.draw_scene_3d(&world, scene_view) {
		rl.DrawText("No active Camera3D entity", 24, 24, 28, rl.MAROON)
		return
	}
	rl.DrawText("Rune Third-Person Controller", 24, 24, 28, rl.DARKGRAY)
	rl.DrawText("WASD: move   Space: jump   Mouse wheel: zoom", 24, 60, 18, rl.DARKGRAY)
	rl.DrawText("Left mouse: orbit camera   Right mouse: orbit and turn player", 24, 86, 18, rl.GRAY)
	rl.DrawText("Static boxes and sphere collide.", 24, 110, 18, rl.GRAY)
	rl.DrawFPS(24, 130)
}

main :: proc() {
	game, ok := rune.init("examples/third_person_3d/project.json")
	if !ok { fmt.eprintln("Could not load examples/third_person_3d/project.json"); return }
	defer rune.shutdown(&game)

	scene_ok: bool
	world, scene_ok = rune.load_scene(&game, "examples/third_person_3d/scenes/main.scene.json")
	if !scene_ok { fmt.eprintln("Could not load the third-person scene"); return }
	player, scene_ok = ecs.find_entity_by_id(&world, "player")
	if !scene_ok { fmt.eprintln("Scene is missing entity ID: player"); return }
	follow_camera, scene_ok = ecs.find_entity_by_id(&world, "follow_camera")
	if !scene_ok { fmt.eprintln("Scene is missing entity ID: follow_camera"); return }

	update_follow_camera()
	rune.run(&game, on_update, on_draw)
}
