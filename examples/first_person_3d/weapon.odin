package main

import "core:math"
import rune "rune:core"
import "rune:ecs"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

Weapon_Viewmodel :: struct {
	enabled: bool,
	position, rotation: [3]f32,
	scale, fov: f32,
	jump_motion_strength: f32,
}
Weapon_Viewmodel_Defaults :: Weapon_Viewmodel {
	enabled = true,
	position = {0.24, -0.22, -0.5},
	rotation = {-3, -6, -3},
	scale = 1,
	fov = 55,
	jump_motion_strength = 1,
}
weapon_target: rl.RenderTexture2D

Weapon_Jump_Motion :: struct {
	initialized, grounded: bool,
	vertical_speed: f32,
	previous_offset, offset, velocity: f32,
}
weapon_jump: Weapon_Jump_Motion

// Sample after every physics tick, so short hops and buffered jumps are not
// missed when several simulation steps occur within one rendered frame.
update_weapon_motion :: proc(game: ^rune.Engine, world: ^ecs.World) {
	settings, found := ecs.get(world, player, Weapon_Viewmodel)
	motor, has_motor := ecs.get_character_controller_3d_state(world, player)
	config, has_config := ecs.get_character_controller_3d(world, player)
	if !found || !has_motor || !has_config || !motor.active || !settings.enabled || settings.jump_motion_strength <= 0 {
		weapon_jump = {}
		return
	}
	advance_weapon_jump(&weapon_jump, motor, config, game.fixed_delta_time)
}

advance_weapon_jump :: proc(state: ^Weapon_Jump_Motion, motor: ecs.Character_Controller_State_3D, config: ecs.CharacterController3D, dt: f32) {
	if dt <= 0 {return}
	if !state.initialized {
		state^ = {initialized = true, grounded = motor.grounded, vertical_speed = motor.velocity[1]}
	}
	state.previous_offset = state.offset
	jump_speed := max(config.jump_speed, 1)
	if !motor.grounded && motor.velocity[1] > 1 && motor.velocity[1] > state.vertical_speed+1 {
		// Actual upward acceleration, including coyote/buffered jumps, not a key press.
		state.velocity -= 10
	}
	if motor.grounded && !state.grounded {
		impact := clamp((motor.support_velocity[1]-state.vertical_speed)/jump_speed, 0, 1.5)
		if impact > 0.1 {state.velocity -= 20*impact}
	}
	// Rising lowers the weapon slightly; falling lets it float back up.
	target := f32(0)
	if !motor.grounded {target = -0.3*clamp(motor.velocity[1]/jump_speed, -1, 1)}
	// Exact damped spring step avoids frame-rate-dependent integration/overshoot.
	omega, damping := f32(20), f32(13)
	frequency := math.sqrt(omega*omega-damping*damping)
	x := state.offset-target
	decay := math.exp(-damping*dt)
	c, s := math.cos(frequency*dt), math.sin(frequency*dt)
	state.offset = target+decay*(x*c+(state.velocity+damping*x)/frequency*s)
	state.velocity = decay*(state.velocity*c-(damping*state.velocity+omega*omega*x)/frequency*s)
	if motor.grounded && math.abs(state.offset)+math.abs(state.velocity) < 0.0001 {
		state.offset, state.velocity = 0, 0
	}
	state.grounded, state.vertical_speed = motor.grounded, motor.velocity[1]
}

shutdown_weapon :: proc() {
	if weapon_target.id != 0 {rl.UnloadRenderTexture(weapon_target)}
	weapon_target = {}
}

// Called after the world/canvas and before the HUD. A separate depth buffer
// keeps the weapon in front of the level while preserving its self-occlusion.
draw_weapon :: proc(game: ^rune.Engine, world: ^ecs.World) {
	settings, found := ecs.get(world, player, Weapon_Viewmodel)
	if !found || !settings.enabled || settings.scale <= 0 {return}
	width, height := rl.GetRenderWidth(), rl.GetRenderHeight()
	if width <= 0 || height <= 0 {return}
	if weapon_target.texture.width != width || weapon_target.texture.height != height {
		shutdown_weapon()
		weapon_target = rl.LoadRenderTexture(width, height)
		if !rl.IsRenderTextureValid(weapon_target) {shutdown_weapon(); return}
		rl.SetTextureFilter(weapon_target.texture, .BILINEAR)
	}
	rl.BeginTextureMode(weapon_target)
	rl.ClearBackground({0, 0, 0, 0})
	rl.BeginMode3D({position = {}, target = {0, 0, -1}, up = {0, 1, 0}, fovy = clamp(settings.fov, 10, 120), projection = .PERSPECTIVE})
	rlgl.PushMatrix()
	alpha := clamp(game.fixed_accumulator/game.fixed_delta_time, 0, 1)
	jump := (weapon_jump.previous_offset+(weapon_jump.offset-weapon_jump.previous_offset)*alpha)*clamp(settings.jump_motion_strength, 0, 3)
	// Camera-local geometry follows look/crouch automatically; a small inverse
	// offset lets the existing head bob move the weapon gently in the view.
	rlgl.Translatef(settings.position[0]-head_bob.offset[0]*0.7, settings.position[1]-head_bob.offset[1]*0.7+jump*0.045, settings.position[2]-jump*0.012)
	rlgl.Rotatef(settings.rotation[2], 0, 0, 1)
	rlgl.Rotatef(settings.rotation[1], 0, 1, 0)
	rlgl.Rotatef(settings.rotation[0]+jump*4, 1, 0, 0)
	rlgl.Scalef(settings.scale, settings.scale, settings.scale)
	draw_placeholder_weapon()
	rlgl.PopMatrix()
	rl.EndMode3D()
	rl.EndTextureMode()
	rl.DrawTexturePro(weapon_target.texture, {0, 0, f32(width), -f32(height)},
		{0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}, {}, 0, rl.WHITE)
}

// Face shading gives the blockout readable form without world lighting/assets.
weapon_box :: proc(position, size: [3]f32, color: rl.Color) {
	h := size*0.5
	vertices := [8][3]f32 {
		{-h[0], -h[1], -h[2]}, {h[0], -h[1], -h[2]},
		{h[0], h[1], -h[2]}, {-h[0], h[1], -h[2]},
		{-h[0], -h[1], h[2]}, {h[0], -h[1], h[2]},
		{h[0], h[1], h[2]}, {-h[0], h[1], h[2]},
	}
	faces := [6][4]int {{4,5,6,7}, {1,0,3,2}, {5,1,2,6}, {0,4,7,3}, {7,6,2,3}, {0,1,5,4}}
	shades := [6]f32 {0.8, 0.65, 0.7, 0.86, 1, 0.55}
	rlgl.Begin(rlgl.QUADS)
	for face, i in faces {
		rlgl.Color4ub(u8(f32(color.r)*shades[i]), u8(f32(color.g)*shades[i]), u8(f32(color.b)*shades[i]), 255)
		for index in face {
			v := position+vertices[index]
			rlgl.Vertex3f(v[0], v[1], v[2])
		}
	}
	rlgl.End()
}

draw_placeholder_weapon :: proc() {
	// Compact blockout carbine, muzzle pointing down camera-local -Z.
	weapon_box({0, 0, -0.12}, {0.13, 0.15, 0.38}, {70, 85, 102, 255}) // receiver
	weapon_box({0, -0.02, 0.17}, {0.115, 0.16, 0.2}, {45, 53, 65, 255}) // stock
	weapon_box({0, -0.15, 0.015}, {0.075, 0.2, 0.105}, {94, 77, 58, 255}) // grip
	weapon_box({0, -0.15, -0.17}, {0.08, 0.19, 0.11}, {43, 50, 58, 255}) // magazine
	weapon_box({0, 0.005, -0.39}, {0.11, 0.12, 0.19}, {102, 116, 130, 255}) // fore-end
	weapon_box({0, 0.09, -0.18}, {0.055, 0.035, 0.39}, {32, 39, 48, 255}) // rail
	weapon_box({0, 0.125, -0.055}, {0.065, 0.045, 0.08}, {61, 73, 88, 255}) // rear sight
	weapon_box({0, 0.116, -0.4}, {0.024, 0.065, 0.03}, {40, 47, 58, 255}) // front sight
	weapon_box({0.067, 0.012, -0.16}, {0.008, 0.028, 0.19}, {218, 169, 78, 255}) // accent
	weapon_box({0, 0.013, -0.55}, {0.05, 0.055, 0.18}, {44, 51, 60, 255}) // barrel
	weapon_box({0, 0.013, -0.658}, {0.075, 0.075, 0.065}, {30, 36, 45, 255}) // muzzle
}
