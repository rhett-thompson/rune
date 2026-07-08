package main

import "core:os"
import r3d "r3d:r3d"
import rl "vendor:raylib"

main :: proc() {
	capture := len(os.args) > 1 && os.args[1] == "--capture"
	rl.SetConfigFlags({.MSAA_4X_HINT})
	rl.InitWindow(960, 540, "Rune r3d Shadow Probe")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	if !r3d.Init(rl.GetScreenWidth(), rl.GetScreenHeight()) {
		return
	}
	defer r3d.Close()
	r3d.SetAntiAliasingMode(.FXAA)

	ground := r3d.GenMeshPlane(1000, 1000, 1, 1)
	defer r3d.UnloadMesh(ground)
	sphere := r3d.GenMeshSphere(0.5, 64, 64)
	defer r3d.UnloadMesh(sphere)
	material := r3d.GetDefaultMaterial()

	env := r3d.GetEnvironment()
	env.ambient.color = {10, 10, 10, 255}

	light := r3d.CreateLight(.SPOT)
	defer r3d.DestroyLight(light)
	r3d.LightLookAt(light, {0, 10, 5}, {0, 0, 0})
	r3d.SetLightActive(light, true)
	r3d.EnableShadow(light)

	camera: rl.Camera3D = {
		position = {0, 2, 2},
		target = {0, 0, 0},
		up = {0, 1, 0},
		fovy = 60,
		projection = .PERSPECTIVE,
	}

	frame := 0
	for !rl.WindowShouldClose() {
		rl.UpdateCamera(&camera, .ORBITAL)
		rl.BeginDrawing()
		rl.ClearBackground({8, 10, 14, 255})
		r3d.Begin(camera)
		r3d.DrawMesh(ground, material, {0, -0.5, 0}, 1)
		r3d.DrawMesh(sphere, material, {0, 0, 0}, 1)
		r3d.End()
		rl.DrawText("r3d shadow probe: upstream basic + capture", 24, 24, 20, rl.RAYWHITE)
		rl.DrawFPS(24, 54)
		if capture && frame == 30 {
			rl.TakeScreenshot("build/r3d_shadow_probe.png")
		}
		rl.EndDrawing()
		if capture && frame > 32 {
			break
		}
		frame += 1
	}
}
