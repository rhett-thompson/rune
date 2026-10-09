package r3d_bridge

import r3d "r3d:r3d"
import rl "vendor:raylib"

// A separate native chain leaves the bundled screen-stage/core-state ABI
// intact. It runs after opaque unlit surfaces and before alpha blending.
// See third_party/r3d-shadows/pre-transparency.patch and its rebuild guide.
PRE_TRANSPARENCY_SHADERS_SUPPORTED :: ODIN_ARCH == .amd64 && (ODIN_OS == .Windows || ODIN_OS == .Linux)

when ODIN_ARCH == .amd64 && ODIN_OS == .Windows {
	@(require)
	@(extra_linker_flags="/NODEFAULTLIB:" + ("msvcrt" when rl.RAYLIB_SHARED else "libcmt"))
	foreign import pre_transparency_lib {
		"../../third_party/r3d-shadows/windows/pre_transparency.obj",
		"../../third_party/r3d-odin/r3d/windows/r3d.lib",
		"vendor:raylib/windows/raylibdll.lib" when rl.RAYLIB_SHARED else "vendor:raylib/windows/raylib.lib",
		"system:Winmm.lib",
		"system:Gdi32.lib",
		"system:User32.lib",
		"system:Shell32.lib",
	}
} else when ODIN_ARCH == .amd64 && ODIN_OS == .Linux {
	@(require)
	foreign import pre_transparency_lib {
		"../../third_party/r3d-shadows/linux/pre_transparency.o",
		"../../third_party/r3d-odin/r3d/linux/libr3d.a",
		"vendor:raylib/linux/libraylib.so.600" when rl.RAYLIB_SHARED else "vendor:raylib/linux/libraylib.a",
		"system:dl",
		"system:pthread",
		"system:X11",
		"system:m",
	}
}

when PRE_TRANSPARENCY_SHADERS_SUPPORTED {
	@(default_calling_convention="c")
	foreign pre_transparency_lib {
		@(link_name="Rune_R3D_SetPreTransparencyShaderChain")
		set_pre_transparency_shader_chain :: proc(shaders: [^]^r3d.ScreenShader, count: i32) ---
	}
} else {
	// Keep the previous post-scene path on targets without the owned object.
	set_pre_transparency_shader_chain :: proc(shaders: [^]^r3d.ScreenShader, count: i32) {
		r3d.SetScreenShaderChain(.SCENE, shaders, count)
	}
}
