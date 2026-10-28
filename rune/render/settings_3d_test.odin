package render

import "core:testing"

@(test)
settings_3d_accepts_defaults_and_bounded_shadow_resolutions :: proc(t:^testing.T) {
	defaults:=default_settings_3d()
	testing.expect(t,defaults.shadows==Shadow_Map_Settings{4096,2048,2048})
	testing.expect(t,settings_3d_valid(defaults))
	// R3D accepts integer dimensions; powers of two are not required.
	testing.expect(t,settings_3d_valid({shadows={2,257,8192}}))
	for invalid in ([4]i32{-1,0,1,8193}) {
		for field in 0..<3 {
			settings:=defaults
			switch field {
			case 0: settings.shadows.directional_resolution=invalid
			case 1: settings.shadows.spot_resolution=invalid
			case 2: settings.shadows.omni_resolution=invalid
			}
			testing.expect(t,!settings_3d_valid(settings),"every shadow type enforces the resolution bounds")
		}
	}
}
