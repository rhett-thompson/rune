package main

import "core:fmt"
import "core:math"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import "rune:render"
import rl "vendor:raylib"

world: ecs.World

scene_view := render.Scene3D_Settings{
	grid_slices = 20,
	grid_spacing = 1,
}

orbit_camera: ecs.Entity

orbit_angle: f32
orbit_elevation: f32 = 27

orbit_radius    :: f32(8)
orbit_target_y  :: f32(0.75)
auto_orbit_speed :: f32(35)
mouse_orbit_speed :: f32(0.35)

on_update :: proc(game: ^rune.Engine) {
	if input.is_down(rune.input_state(game), "orbit_camera") {
		orbit_angle -= input.axis(rune.input_state(game), "orbit_x") * mouse_orbit_speed
		orbit_elevation += input.axis(rune.input_state(game), "orbit_y") * mouse_orbit_speed
		if orbit_elevation < -80 { orbit_elevation = -80 }
		if orbit_elevation > 80 { orbit_elevation = 80 }
	} else {
		orbit_angle += auto_orbit_speed * game.delta_time
	}
	if orbit_angle >= 360 { orbit_angle -= 360 }
	if orbit_angle < 0 { orbit_angle += 360 }

	transform, found := ecs.get_transform(&world, orbit_camera)
	if !found {
		return
	}

	angle := orbit_angle * f32(math.PI / 180)
	elevation := orbit_elevation * f32(math.PI / 180)
	horizontal_radius := orbit_radius * f32(math.cos(f64(elevation)))
	transform.position = {
		horizontal_radius * f32(math.cos(f64(angle))),
		orbit_target_y + orbit_radius * f32(math.sin(f64(elevation))),
		horizontal_radius * f32(math.sin(f64(angle))),
	}
	ecs.set_transform(&world, orbit_camera, transform)
}

on_draw :: proc(game: ^rune.Engine) {
	if !render.draw_scene_3d(&world, scene_view) {
		rl.DrawText("No active Camera3D entity", 24, 24, 28, rl.MAROON)
		return
	}

	rl.DrawText("Camera3D Orbit", 24, 24, 28, rl.DARKGRAY)
	rl.DrawText("The Camera3D entity's Transform orbits its JSON target.", 24, 60, 18, rl.GRAY)
	rl.DrawText("Hold left mouse and drag to orbit manually.", 24, 86, 18, rl.DARKGRAY)
	rl.DrawFPS(24, 112)
}

main :: proc() {
	game, ok := rune.init("examples/orbit_camera/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/orbit_camera/project.json")
		return
	}

	scene_ok: bool
	world, scene_ok = rune.load_scene(&game, "examples/orbit_camera/scenes/main.scene.json")
	if !scene_ok {
		fmt.eprintln("Could not load and instantiate the orbit-camera scene")
		rune.shutdown(&game)
		return
	}
	found: bool
	orbit_camera, found = ecs.find_entity_by_id(&world, "orbit_camera")
	if !found {
		fmt.eprintln("Scene is missing entity ID: orbit_camera")
		rune.shutdown(&game)
		return
	}

	rune.run(&game, on_update, on_draw)
}
