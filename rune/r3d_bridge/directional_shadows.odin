package r3d_bridge

import rl "vendor:raylib"
import r3d "r3d:r3d"

// Keep directional shadow coverage independent of camera rotation. The owned
// native light and shader modules replace the corresponding bundled R3D
// archive members. Surface taps follow the receiver plane to keep small shadows
// without grazing-angle self-occlusion. Required objects link before archives.
// See third_party/r3d-shadows/README.md for the exact source pin and rebuild.
when ODIN_ARCH == .amd64 && ODIN_OS == .Windows {
	// Raw objects retain native code even when callers only use pure Odin
	// bridge helpers. Carry raylib's platform dependencies and CRT selection
	// here because its ordinary foreign import can otherwise be discarded.
	@(require)
	@(extra_linker_flags="/NODEFAULTLIB:" + ("msvcrt" when rl.RAYLIB_SHARED else "libcmt"))
	foreign import stable_shadow_lib {
		"../../third_party/r3d-shadows/windows/shadows.obj",
		"../../third_party/r3d-shadows/windows/receiver_shader.obj",
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
	foreign import stable_shadow_lib {
		"../../third_party/r3d-shadows/linux/shadows.o",
		"../../third_party/r3d-shadows/linux/receiver_shader.o",
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
	// Foreign imports have file scope. Keep the declaration with the shared
	// object/archive list so GNU ld sees every replacement before the archive.
	@(default_calling_convention="c")
	foreign stable_shadow_lib {
		@(link_name="Rune_R3D_SetPreTransparencyShaderChain")
		set_pre_transparency_shader_chain :: proc(shaders: [^]^r3d.ScreenShader, count: i32) ---
	}
}
