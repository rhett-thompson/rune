package main

import "core:fmt"
import "core:os"
import r3d "r3d:r3d"
import rune "rune:core"
import rl "vendor:raylib"

capture: bool
frame: int
ground: r3d.Mesh
sphere: r3d.Mesh
material: r3d.Material
light: r3d.Light
camera: rl.Camera3D

on_update :: proc(game: ^rune.Engine) {}

on_draw :: proc(game: ^rune.Engine) {
	rl.UpdateCamera(&camera, .ORBITAL)
	r3d.Begin(camera)
	r3d.DrawMesh(ground, material, {0, -0.5, 0}, 1)
	r3d.DrawMesh(sphere, material, {0, 0, 0}, 1)
	r3d.End()
	if capture && frame == 30 {
		rl.TakeScreenshot("build/r3d_engine_probe.png")
	}
	frame += 1
	if capture && frame > 32 {
		rune.request_exit(game)
	}
}

main :: proc() {
	capture = len(os.args) > 1 && os.args[1] == "--capture"
	game, ok := rune.init("examples/r3d_engine_probe/project.json")
	if !ok {
		fmt.eprintln("Could not load examples/r3d_engine_probe/project.json")
		return
	}
	defer rune.shutdown(&game)

	if !r3d.Init(rl.GetScreenWidth(), rl.GetScreenHeight()) {
		fmt.eprintln("Could not initialize r3d")
		return
	}
	defer r3d.Close()
	r3d.SetAntiAliasingMode(.FXAA)

	ground = r3d.GenMeshPlane(1000, 1000, 1, 1)
	defer r3d.UnloadMesh(ground)
	sphere = r3d.GenMeshSphere(0.5, 64, 64)
	defer r3d.UnloadMesh(sphere)
	material = r3d.GetDefaultMaterial()

	env := r3d.GetEnvironment()
	env.ambient.color = {10, 10, 10, 255}

	light = r3d.CreateLight(.SPOT)
	defer r3d.DestroyLight(light)
	r3d.LightLookAt(light, {0, 10, 5}, {0, 0, 0})
	r3d.SetLightActive(light, true)
	r3d.EnableShadow(light)

	camera = {
		position   = {0, 2, 2},
		target     = {0, 0, 0},
		up         = {0, 1, 0},
		fovy       = 60,
		projection = .PERSPECTIVE,
	}
	rune.run(&game, on_update, on_draw)
}
