package r3d_bridge

import r3d "r3d:r3d"

// A separate native chain leaves the bundled screen-stage/core-state ABI
// intact. It runs after opaque unlit surfaces and before alpha blending.
// See third_party/r3d-shadows/pre-transparency.patch and its rebuild guide.
PRE_TRANSPARENCY_SHADERS_SUPPORTED :: ODIN_ARCH == .amd64 && (ODIN_OS == .Windows || ODIN_OS == .Linux)

when !PRE_TRANSPARENCY_SHADERS_SUPPORTED {
	// Keep the previous post-scene path on targets without the owned object.
	set_pre_transparency_shader_chain :: proc(shaders: [^]^r3d.ScreenShader, count: i32) {
		r3d.SetScreenShaderChain(.SCENE, shaders, count)
	}
}
