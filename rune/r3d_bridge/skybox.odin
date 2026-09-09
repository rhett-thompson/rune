package r3d_bridge

import "core:strings"
import "rune:assets"
import "rune:ecs"
import r3d "r3d:r3d"
import rl "vendor:raylib"

Skybox_Cache :: struct {
	cubemap: r3d.Cubemap,
	requested: ecs.Skybox,
	revision: u64,
	attempted: bool,
	atmosphere_shader: ^r3d.SkyShader,
	moon_shader: ^r3d.ScreenShader,
	sun: Atmospheric_Sun,
	moon: Atmospheric_Sun,
}

skybox_color :: proc(c: [4]u8) -> rl.Color {return {c[0], c[1], c[2], c[3]}}

procedural_sky_parameters :: proc(p: ecs.Procedural_Sky) -> r3d.ProceduralSky {
	return {
		skyTopColor = skybox_color(p.sky_top_color), skyHorizonColor = skybox_color(p.sky_horizon_color),
		skyHorizonCurve = p.sky_horizon_curve, skyEnergy = p.sky_energy,
		groundBottomColor = skybox_color(p.ground_bottom_color), groundHorizonColor = skybox_color(p.ground_horizon_color),
		groundHorizonCurve = p.ground_horizon_curve, groundEnergy = p.ground_energy,
		sunDirection = p.sun_direction, sunColor = skybox_color(p.sun_color),
		// Zero angular size skips both the disk and halo in r3d's sky shader.
		// Zero energy alone would replace the disk with black.
		sunSize = p.sun_size * rl.DEG2RAD if p.sun_enabled else 0,
		sunCurve = p.sun_curve, sunEnergy = p.sun_energy,
	}
}

release_skybox :: proc(ctx: ^Context) {
	if ctx.skybox.cubemap.texture != 0 {
		env := r3d.GetEnvironment()
		if env.background.sky.texture == ctx.skybox.cubemap.texture {env.background.sky = {}}
		r3d.UnloadCubemap(ctx.skybox.cubemap)
	}
	delete(ctx.skybox.requested.texture)
	delete(ctx.skybox.requested.atmosphere.sun)
	delete(ctx.skybox.requested.atmosphere.moon)
	if ctx.skybox.atmosphere_shader != nil {r3d.UnloadSkyShader(ctx.skybox.atmosphere_shader)}
	if ctx.skybox.moon_shader != nil {r3d.UnloadScreenShader(ctx.skybox.moon_shader)}
	ctx.skybox = {}
}

apply_skybox :: proc(ctx: ^Context, world: ^ecs.World, manager: ^assets.Asset_Manager, camera: ecs.Entity) {
	value, found := ecs.active_skybox(world, camera)
	if !found {release_skybox(ctx); return}
	if value.mode == .atmospheric {
		apply_atmosphere(ctx, world, manager, value)
		return
	}
	revision: u64
	if value.mode == .cubemap {revision = assets.skybox_revision(manager, value.texture)}
	cache := &ctx.skybox
	previous := cache.requested
	same_source := cache.attempted && previous.mode == value.mode &&
		(previous.texture == value.texture && previous.layout == value.layout if value.mode == .cubemap else
		 previous.procedural == value.procedural && previous.resolution == value.resolution)
	if !same_source || cache.revision != revision {
		// Only a reload of the same source retains its last good GPU image.
		if !same_source {release_skybox(ctx)}
		loaded: r3d.Cubemap
		if value.mode == .procedural {
			loaded = r3d.GenProceduralSky(value.resolution, procedural_sky_parameters(value.procedural))
		} else {
			path := assets.resolve_path(manager, value.texture) if manager != nil else resolve_path(ctx, value.texture)
			cpath := strings.clone_to_cstring(path, context.temp_allocator)
			loaded = r3d.LoadCubemap(cpath, r3d.CubemapLayout(value.layout))
		}
		if loaded.texture != 0 {
			if cache.cubemap.texture != 0 {r3d.UnloadCubemap(cache.cubemap)}
			cache.cubemap = loaded
			assets.resolve_asset_failure(manager, "", "Skybox.texture", value.texture)
		} else {
			assets.report_failure(manager, {kind = .Skybox, operation = .Reload if cache.cubemap.texture != 0 else .Load,
				field = "Skybox.texture", asset_path = value.texture,
				detail = "could not load skybox; keeping previous image" if cache.cubemap.texture != 0 else "could not load skybox; using background color"})
		}
		delete(cache.requested.texture)
		delete(cache.requested.atmosphere.sun)
		delete(cache.requested.atmosphere.moon)
		cache.requested = value
		cache.requested.texture = strings.clone(value.texture)
		cache.requested.atmosphere.sun = strings.clone(value.atmosphere.sun)
		cache.requested.atmosphere.moon = strings.clone(value.atmosphere.moon)
		cache.revision = revision
		cache.attempted = true
	}
	if cache.cubemap.texture != 0 {
		env := r3d.GetEnvironment()
		env.background.sky = cache.cubemap
		env.background.energy = value.energy
		env.background.rotation = rotation_quaternion(ecs.Transform{rotation = value.rotation})
	}
}
