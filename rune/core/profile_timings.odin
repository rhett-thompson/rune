package core

import "core:time"
import "rune:ecs"

debug_profile_release_samples :: proc(debug: ^Debug_State) {
	if debug.profile_samples != nil {delete(debug.profile_samples, debug.profile_allocator)}
	debug.profile_samples = nil
	debug.profile_allocator = {}
}

// These stage durations overlap the broad update/fixed/render totals. Timers
// measure synchronous elapsed time, including joins; they are not worker CPU
// totals. Player builds omit the additional native timer calls.
debug_profile_started :: proc() -> time.Tick {
	when Player_Build {return {}}
	return time.tick_now()
}

debug_profile_elapsed_ms :: proc(started: time.Tick) -> f64 {
	when Player_Build {return 0}
	return time.duration_milliseconds(time.tick_since(started))
}

profiled_sync_terrains :: proc(engine: ^Engine, world: ^ecs.World) {
	started := debug_profile_started()
	ecs.sync_terrains(world, &engine.assets)
	engine.debug.sample.terrain_sync_ms += debug_profile_elapsed_ms(started)
}

profiled_sync_navigation_3d :: proc(engine: ^Engine, world: ^ecs.World) {
	started := debug_profile_started()
	ecs.sync_navigation_3d(world, &engine.assets)
	engine.debug.sample.navigation_3d_ms += debug_profile_elapsed_ms(started)
}

Debug_Profile_Result :: struct {
	frames, stepped_frames: int,
	frame, update, fixed_update, render_submission: Timing_Summary,
	physics_3d, physics_2d, navigation_3d: Timing_Summary,
	terrain_sync, asset_refresh, scene_reload, game_systems: Timing_Summary,
}

debug_profile_summary :: proc(samples: []Profile_Sample, stepped_frames: int) -> Debug_Profile_Result {
	count := len(samples)
	if count == 0 {return {}}
	// Contiguous columns let the existing in-place percentile helper sort one
	// metric without modifying the stored per-frame samples or another metric.
	values := make([]f64, 11*count, context.temp_allocator)
	for sample, index in samples {
		values[0*count+index] = sample.frame_ms
		values[1*count+index] = sample.update_ms
		values[2*count+index] = sample.fixed_update_ms
		values[3*count+index] = sample.render_ms
		values[4*count+index] = sample.physics_3d_ms
		values[5*count+index] = sample.physics_2d_ms
		values[6*count+index] = sample.navigation_3d_ms
		values[7*count+index] = sample.terrain_sync_ms
		values[8*count+index] = sample.asset_refresh_ms
		values[9*count+index] = sample.scene_reload_ms
		values[10*count+index] = sample.game_systems_ms
	}
	return {
		frames=count, stepped_frames=stepped_frames,
		frame=timing_summary(values[0*count:1*count]),
		update=timing_summary(values[1*count:2*count]),
		fixed_update=timing_summary(values[2*count:3*count]),
		render_submission=timing_summary(values[3*count:4*count]),
		physics_3d=timing_summary(values[4*count:5*count]),
		physics_2d=timing_summary(values[5*count:6*count]),
		navigation_3d=timing_summary(values[6*count:7*count]),
		terrain_sync=timing_summary(values[7*count:8*count]),
		asset_refresh=timing_summary(values[8*count:9*count]),
		scene_reload=timing_summary(values[9*count:10*count]),
		game_systems=timing_summary(values[10*count:11*count]),
	}
}
