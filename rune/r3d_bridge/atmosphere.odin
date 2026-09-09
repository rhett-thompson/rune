package r3d_bridge

import "core:math"
import "core:strings"
import "rune:assets"
import "rune:ecs"
import r3d "r3d:r3d"
import rl "vendor:raylib"

Atmospheric_Sun :: struct {
	direction: [3]f32, // Toward the sun, opposite the light's ray direction.
	radiance: [3]f32,
}

// Resolve by scene ID each frame: no handles/pointers survive a scene reload.
// A disabled light contributes no radiance but remains a valid reference.
atmospheric_sun :: proc(world: ^ecs.World, id: string) -> (Atmospheric_Sun, bool) {
	entity, exists := ecs.find_entity_by_id(world, id)
	if !exists {return {}, false}
	light, found := ecs.get_directional_light(world, entity)
	if !found {return {}, false}
	if !ecs.finite_nonnegative(light.intensity) {return {}, false}
	maximum: f32
	for v in light.direction {
		if math.is_nan(v) || math.is_inf(v) {return {}, false}
		maximum = max(maximum, abs(v))
	}
	if maximum == 0 {return {}, false}
	// Scale before normalization so very large/small finite directions are safe.
	direction := light.direction / maximum
	direction /= math.sqrt(direction[0]*direction[0]+direction[1]*direction[1]+direction[2]*direction[2])
	energy := min(light.intensity, 10000) if ecs.is_enabled(world, entity) else 0
	color := rl.ColorNormalize(to_raylib_color(light.color))
	return {direction = -direction, radiance = {color[0]*energy*20, color[1]*energy*20, color[2]*energy*20}}, true
}

set_atmosphere_uniforms :: proc(shader: ^r3d.SkyShader, value: ecs.Atmospheric_Sky, sun, moon: Atmospheric_Sun) {
	params, light := value, sun
	moon_light := moon
	night := rl.ColorNormalize(skybox_color(value.night_color))
	night_rgb := [3]f32{night[0],night[1],night[2]} * value.night_energy
	ground := rl.ColorNormalize(skybox_color(value.ground_color))
	ground_rgb := [3]f32{ground[0],ground[1],ground[2]}
	radius := value.sun_size * 0.5 * rl.DEG2RAD
	r3d.SetSkyShaderUniform(shader, "u_sun_direction", &light.direction)
	r3d.SetSkyShaderUniform(shader, "u_sun_radiance", &light.radiance)
	r3d.SetSkyShaderUniform(shader, "u_moon_direction", &moon_light.direction)
	r3d.SetSkyShaderUniform(shader, "u_moon_radiance", &moon_light.radiance)
	r3d.SetSkyShaderUniform(shader, "u_night_color", &night_rgb)
	r3d.SetSkyShaderUniform(shader, "u_ground_color", &ground_rgb)
	r3d.SetSkyShaderUniform(shader, "u_rayleigh", &params.rayleigh)
	r3d.SetSkyShaderUniform(shader, "u_mie", &params.mie)
	r3d.SetSkyShaderUniform(shader, "u_mie_anisotropy", &params.mie_anisotropy)
	r3d.SetSkyShaderUniform(shader, "u_sun_radius", &radius)
}

load_atmosphere_shader :: proc() -> ^r3d.SkyShader {
	source :: #load("atmosphere.glsl", string)
	return r3d.LoadSkyShaderFromMemory(strings.clone_to_cstring(source, context.temp_allocator))
}

apply_atmosphere :: proc(ctx: ^Context, world: ^ecs.World, manager: ^assets.Asset_Manager, value: ecs.Skybox) {
	sun, valid := atmospheric_sun(world, value.atmosphere.sun)
	if !valid {
		release_skybox(ctx)
		assets.report_failure(manager, {kind = .Skybox, field = "Skybox.atmosphere.sun", asset_path = value.atmosphere.sun,
			detail = "expected an entity with a DirectionalLight and a finite nonzero direction; using background color"})
		return
	}
	assets.resolve_asset_failure(manager, "", "Skybox.atmosphere.sun", value.atmosphere.sun)
	moon := Atmospheric_Sun{direction = {0,1,0}}
	// A missing optional source must not take down the rest of the sky.
	if len(value.atmosphere.moon) > 0 {
		resolved, moon_valid := atmospheric_sun(world, value.atmosphere.moon)
		if moon_valid {
			moon = resolved
			assets.resolve_asset_failure(manager, "", "Skybox.atmosphere.moon", value.atmosphere.moon)
		} else {
			assets.report_failure(manager, {kind = .Skybox, field = "Skybox.atmosphere.moon", asset_path = value.atmosphere.moon,
				detail = "expected an entity with a DirectionalLight and a finite nonzero direction; rendering without the moon"})
		}
	}
	cache := &ctx.skybox
	if cache.requested.atmosphere.moon != value.atmosphere.moon {
		assets.resolve_asset_failure(manager, "", "Skybox.atmosphere.moon", cache.requested.atmosphere.moon)
	}
	if cache.requested.mode != .atmospheric || cache.requested.resolution != value.resolution {
		release_skybox(ctx)
	}
	changed := !cache.attempted || cache.requested.atmosphere != value.atmosphere || cache.sun != sun || cache.moon != moon
	if changed {
		if !cache.attempted {
			cache.atmosphere_shader = load_atmosphere_shader()
			source :: #load("moon_disk.glsl", string)
			cache.moon_shader = r3d.LoadScreenShaderFromMemory(strings.clone_to_cstring(source, context.temp_allocator))
			if cache.moon_shader == nil {
				assets.report_failure(manager, {kind = .Skybox, field = "Skybox.atmosphere.moon", asset_path = "",
					detail = "could not load moon disk shader; rendering atmospheric haze only"})
			} else {assets.resolve_asset_failure(manager, "", "Skybox.atmosphere.moon", "")}
		}
		if cache.atmosphere_shader != nil {
			set_atmosphere_uniforms(cache.atmosphere_shader, value.atmosphere, sun, moon)
			if cache.cubemap.texture == 0 {
				cache.cubemap = r3d.GenCustomSky(value.resolution, cache.atmosphere_shader)
			} else {
				r3d.UpdateCustomSky(&cache.cubemap, cache.atmosphere_shader)
			}
		}
		if cache.cubemap.texture == 0 {
			assets.report_failure(manager, {kind = .Skybox, field = "Skybox.atmosphere", asset_path = "",
				detail = "could not generate atmospheric sky; using background color"})
		} else {assets.resolve_asset_failure(manager, "", "Skybox.atmosphere", "")}
		delete(cache.requested.texture)
		delete(cache.requested.atmosphere.sun)
		delete(cache.requested.atmosphere.moon)
		cache.requested = value
		cache.requested.texture = strings.clone(value.texture)
		cache.requested.atmosphere.sun = strings.clone(value.atmosphere.sun)
		cache.requested.atmosphere.moon = strings.clone(value.atmosphere.moon)
		cache.sun = sun
		cache.moon = moon
		cache.revision += 1
		cache.attempted = true
	}
	if cache.cubemap.texture != 0 {
		env := r3d.GetEnvironment()
		env.background.sky = cache.cubemap
		env.background.energy = value.energy
		// The atmosphere and sun are world-aligned with the directional light.
		env.background.rotation = quaternion128(1)
	}
}

// SCENE runs before bloom/tonemapping. The depth buffer masks foreground objects.
// The bridge owns this stage during its draw; clear the chain immediately after End.
prepare_moon_disk :: proc(ctx: ^Context) -> bool {
	cache := &ctx.skybox
	if cache.moon_shader == nil || cache.cubemap.texture == 0 || cache.moon.radiance == ([3]f32{}) {return false}
	env := r3d.GetEnvironment()
	energy := env.background.energy
	if env.fog.mode != .DISABLED {energy *= 1-clamp(env.fog.skyAffect, 0, 1)}
	if energy <= 0 {return false}
	radius := cache.requested.atmosphere.moon_size * 0.5 * rl.DEG2RAD
	r3d.SetScreenShaderUniform(cache.moon_shader, "u_direction", &cache.moon.direction)
	r3d.SetScreenShaderUniform(cache.moon_shader, "u_radiance", &cache.moon.radiance)
	r3d.SetScreenShaderUniform(cache.moon_shader, "u_radius", &radius)
	r3d.SetScreenShaderUniform(cache.moon_shader, "u_energy", &energy)
	r3d.SetScreenShaderUniform(cache.moon_shader, "u_rayleigh", &cache.requested.atmosphere.rayleigh)
	r3d.SetScreenShaderUniform(cache.moon_shader, "u_mie", &cache.requested.atmosphere.mie)
	chain := [1]^r3d.ScreenShader{cache.moon_shader}
	r3d.SetScreenShaderChain(.SCENE, raw_data(chain[:]), 1)
	return true
}
