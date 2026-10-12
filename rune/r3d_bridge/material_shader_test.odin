package r3d_bridge

import "core:testing"

@(test)
material_shader_clock_supports_default_pause_and_reproducible_zero :: proc(t: ^testing.T) {
	testing.expect(t, material_shader_clock({}, 12.5) == 12.5)
	settings := Scene3D_Settings{material_time_override=true, material_time=3.25}
	testing.expect(t, material_shader_clock(settings, 12.5) == 3.25)
	testing.expect(t, material_shader_clock(settings, 99) == 3.25, "a paused simulation keeps its material clock")
	settings.material_time = 0
	testing.expect(t, material_shader_clock(settings, 99) == 0, "explicit time zero must not fall back to wall time")
}
