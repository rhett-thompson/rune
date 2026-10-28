package core

import "core:mem"
import "core:testing"

@(test)
profile_summary_retains_legacy_fields_and_independent_stage_percentiles :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena); defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	samples: [20]Profile_Sample
	for &sample, index in samples {
		value := f64(len(samples)-index)
		sample = {frame_ms=value, update_ms=2*value, fixed_update_ms=3*value, render_ms=4*value,
			physics_3d_ms=5*value, physics_2d_ms=6*value, navigation_3d_ms=7*value,
			terrain_sync_ms=8*value, asset_refresh_ms=9*value, scene_reload_ms=10*value, game_systems_ms=11*value}
	}
	result := debug_profile_summary(samples[:], 17)
	testing.expect(t, result.frames == 20 && result.stepped_frames == 17)
	for summary, index in ([11]Timing_Summary{result.frame,result.update,result.fixed_update,result.render_submission,
		result.physics_3d,result.physics_2d,result.navigation_3d,result.terrain_sync,result.asset_refresh,result.scene_reload,result.game_systems}) {
		factor := f64(index+1)
		testing.expect(t, summary.mean_ms == 10.5*factor && summary.max_ms == 20*factor && summary.p95_ms == 19*factor,
			"each metric uses its own samples and nearest-rank p95")
	}
	testing.expect(t, samples[0].frame_ms == 20 && samples[0].physics_3d_ms == 100,
		"summarizing leaves per-frame samples unchanged")
	testing.expect(t, debug_profile_summary(nil,0) == Debug_Profile_Result{})
}
