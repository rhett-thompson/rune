package r3d_bridge

import "core:testing"
import "rune:render"
import r3d "r3d:r3d"
import rl "vendor:raylib"

@(test)
renderer_init_rejects_invalid_settings_before_native_access :: proc(t:^testing.T) {
	settings:=render.default_settings_3d()
	settings.shadows.spot_resolution=0
	ctx,ok:=init("",64,64,settings)
	testing.expect(t,!ok && !ctx.initialized,"invalid settings fail before accessing a graphics context")
}

when #config(RUNE_SHADOW_MAP_GPU_TESTS,false) {
	@(test)
	renderer_shadow_settings_reach_native_maps_and_reset_on_reinit :: proc(t:^testing.T) {
		rl.SetConfigFlags({.WINDOW_HIDDEN})
		rl.InitWindow(64,64,"Shadow map startup settings regression");defer rl.CloseWindow()
		if !testing.expect(t,rl.IsWindowReady(),"native shadow validation requires an OpenGL context") {return}
		settings:=render.Settings_3D{shadows={256,128,64}}
		ctx,ok:=init("",64,64,settings)
		if !testing.expect(t,ok) {return}
		defer shutdown(&ctx)
		expected:=[3]i32{256,128,64}
		for hint,index in ([3]r3d.Hint{.SHADOW_DIR_SIZE,.SHADOW_SPOT_SIZE,.SHADOW_OMNI_SIZE}) {
			testing.expect(t,r3d.GetHint(hint)==expected[index],"native initialization receives every configured resolution")
		}
		for light_type in ([3]r3d.LightType{.DIR,.SPOT,.OMNI}) {
			light:=r3d.CreateLight(light_type)
			if !testing.expect(t,r3d.IsLightValid(light)) {continue}
			r3d.EnableShadow(light)
			testing.expect(t,r3d.IsShadowEnabled(light),"each configured light type allocates its shadow map")
			r3d.DestroyLight(light)
		}
		invalid:=settings;invalid.shadows.directional_resolution=8193
		rejected,rejected_ok:=init("",64,64,invalid)
		testing.expect(t,!rejected_ok && !rejected.initialized && r3d.GetHint(.SHADOW_DIR_SIZE)==256,
			"invalid settings cannot modify native hint state")
		shutdown(&ctx)
		ctx,ok=init("",64,64)
		if !testing.expect(t,ok) {return}
		testing.expect(t,r3d.GetHint(.SHADOW_DIR_SIZE)==4096 && r3d.GetHint(.SHADOW_SPOT_SIZE)==2048 && r3d.GetHint(.SHADOW_OMNI_SIZE)==2048,
			"the backward-compatible init call restores default resolutions after shutdown")
	}
}
