package render

// Startup configuration shared by Project and the optional R3D bridge.
// The bridge applies these settings before creating its native renderer.
Settings_3D :: struct {
	shadows: Shadow_Map_Settings,
}

// Each resolution is shared by every shadow-casting light of that type.
// Omni resolution is the width/height of each point-light cubemap face.
Shadow_Map_Settings :: struct {
	directional_resolution: i32,
	spot_resolution: i32,
	omni_resolution: i32,
}

Min_Shadow_Map_Resolution :: 2
Max_Shadow_Map_Resolution :: 8192

Default_Settings_3D :: Settings_3D {
	shadows = {
		directional_resolution = 4096,
		spot_resolution = 2048,
		omni_resolution = 2048,
	},
}

default_settings_3d :: proc() -> Settings_3D {return Default_Settings_3D}

settings_3d_valid :: proc(settings: Settings_3D) -> bool {
	for resolution in ([3]i32{settings.shadows.directional_resolution,
		settings.shadows.spot_resolution,settings.shadows.omni_resolution}) {
		if resolution < Min_Shadow_Map_Resolution || resolution > Max_Shadow_Map_Resolution {return false}
	}
	return true
}
