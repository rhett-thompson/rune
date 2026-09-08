package r3d_bridge

import r3d "r3d:r3d"
import "rune:ecs"
import rl "vendor:raylib"

// Convert without touching background, sky or ambient lighting. Returning a
// value also lets headless tools verify the renderer mapping without a GPU.
post_processing_environment :: proc(base: r3d.Environment, value: ecs.PostProcessing) -> r3d.Environment {
	env := base
	env.bloom = {
		mode = r3d.Bloom(value.bloom.mode),
		levels = value.bloom.levels,
		intensity = value.bloom.intensity,
		threshold = value.bloom.threshold,
		softThreshold = value.bloom.soft_threshold,
		filterRadius = value.bloom.filter_radius,
	}
	env.tonemap = {
		mode = r3d.Tonemap(value.tonemap.mode),
		exposure = value.tonemap.exposure,
		white = value.tonemap.white,
	}
	env.color = {
		brightness = value.color.brightness,
		contrast = value.color.contrast,
		saturation = value.color.saturation,
	}
	env.ssao = {
		enabled = value.ssao.enabled,
		sampleCount = value.ssao.sample_count,
		intensity = value.ssao.intensity,
		power = value.ssao.power,
		maxRadius = value.ssao.max_radius,
		radius = value.ssao.radius,
		bias = value.ssao.bias,
	}
	env.ssil = {
		enabled = value.ssil.enabled,
		sampleCount = value.ssil.sample_count,
		giIntensity = value.ssil.gi_intensity,
		aoIntensity = value.ssil.ao_intensity,
		aoPower = value.ssil.ao_power,
		maxRadius = value.ssil.max_radius,
		radius = value.ssil.radius,
		bias = value.ssil.bias,
	}
	env.ssgi = {
		enabled = value.ssgi.enabled,
		sliceCount = value.ssgi.slice_count,
		edgeFade = value.ssgi.edge_fade,
		distanceFalloff = value.ssgi.distance_falloff,
		normalRejection = value.ssgi.normal_rejection,
		intensity = value.ssgi.intensity,
		denoiseSteps = value.ssgi.denoise_steps,
	}
	env.ssr = {
		enabled = value.ssr.enabled,
		maxRaySteps = value.ssr.max_ray_steps,
		binarySteps = value.ssr.binary_steps,
		stepSize = value.ssr.step_size,
		thickness = value.ssr.thickness,
		maxDistance = value.ssr.max_distance,
		edgeFade = value.ssr.edge_fade,
	}
	env.fog = {
		mode = r3d.Fog(value.fog.mode),
		color = rl.Color{value.fog.color[0], value.fog.color[1], value.fog.color[2], value.fog.color[3]},
		start = value.fog.start,
		end = value.fog.end,
		density = value.fog.density,
		skyAffect = value.fog.sky_affect,
	}
	env.dof = {
		mode = .ENABLED if value.dof.enabled else .DISABLED,
		focusPoint = value.dof.focus_point,
		focusScale = value.dof.focus_scale,
		nearScale = value.dof.near_scale,
		maxBlurSize = value.dof.max_blur_size,
	}
	env.autoExposure = {
		enabled = value.auto_exposure.enabled,
		minEV = value.auto_exposure.min_ev,
		maxEV = value.auto_exposure.max_ev,
		exposureCompensation = value.auto_exposure.exposure_compensation,
		adaptationToBright = value.auto_exposure.adaptation_to_bright,
		adaptationToDark = value.auto_exposure.adaptation_to_dark,
	}
	return env
}

// Save the game-owned baseline only while a Rune profile owns these fields.
// Removing/disabling the last profile restores it; old code-only games remain
// free to configure r3d directly. Global r3d state is not a per-camera renderer.
apply_post_processing :: proc(ctx: ^Context, world: ^ecs.World, camera: ecs.Entity) {
	value, found := ecs.active_post_processing(world, camera)
	if !found {
		if ctx.post_processing_active {
			env := r3d.GetEnvironment()
			background, ambient := env.background, env.ambient
			env^ = ctx.post_processing_baseline
			env.background, env.ambient = background, ambient
			r3d.SetAntiAliasingMode(ctx.post_processing_aa)
			ctx.post_processing_active = false
		}
		return
	}
	if !ctx.post_processing_active {
		ctx.post_processing_baseline = r3d.GetEnvironment()^
		ctx.post_processing_aa = r3d.GetAntiAliasingMode()
		ctx.post_processing_active = true
	}
	env := r3d.GetEnvironment()
	env^ = post_processing_environment(env^, value)
	aa := r3d.AntiAliasingMode(value.anti_aliasing)
	if r3d.GetAntiAliasingMode() != aa {r3d.SetAntiAliasingMode(aa)}
}

