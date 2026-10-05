package r3d_bridge

import "rune:assets"
import "rune:ecs"
import "rune:shadows"
import r3d "r3d:r3d"

native_shadow_defaults :: proc(id: r3d.Light) -> shadows.Settings {
	mode:="continuous"
	switch r3d.GetShadowUpdateMode(id) {
	case .CONTINUOUS: mode="continuous"
	case .INTERVAL: mode="interval"
	case .MANUAL: mode="manual"
	}
	return {enabled=false,softness=r3d.GetShadowSoftness(id),opacity=r3d.GetShadowOpacity(id),
		depth_bias=r3d.GetShadowDepthBias(id),slope_bias=r3d.GetShadowSlopeBias(id),
		update_mode=mode,interval_ms=r3d.GetShadowUpdateFrequency(id)}
}

sync_light_shadows :: proc(ctx: ^Context, manager: ^assets.Asset_Manager, entity: ecs.Entity, id: r3d.Light, light: $T) {
	s:=ctx.scene_shadow_defaults[entity]
	s.enabled=light.shadows
	s.opacity=light.shadow_opacity
	// Legacy zero values mean native defaults. Profile zero values are explicit.
	if light.shadow_softness>0 {s.softness=light.shadow_softness}
	if light.shadow_depth_bias>0 {s.depth_bias=light.shadow_depth_bias}
	if light.shadow_slope_bias>0 {s.slope_bias=light.shadow_slope_bias}
	loaded:=true
	if light.shadow_profile!="" {
		s,_,loaded=assets.shadow_profile(manager,light.shadow_profile)
		if !loaded {s=shadows.Defaults}
	}
	s=shadows.resolve(s,light.shadow_overrides)
	s.enabled=s.enabled && loaded && !light.shadows_disabled && !ctx.shadows_disabled
	previous,existed:=ctx.scene_shadow_settings[entity]
	if existed && previous==s {return}
	if s.enabled {r3d.EnableShadow(id)} else {r3d.DisableShadow(id)}
	r3d.SetShadowSoftness(id,s.softness)
	r3d.SetShadowOpacity(id,s.opacity)
	r3d.SetShadowDepthBias(id,s.depth_bias)
	r3d.SetShadowSlopeBias(id,s.slope_bias)
	mode:=r3d.ShadowUpdateMode.CONTINUOUS
	switch s.update_mode {case "interval": mode=.INTERVAL; case "manual": mode=.MANUAL}
	r3d.SetShadowUpdateMode(id,mode)
	r3d.SetShadowUpdateFrequency(id,s.interval_ms)
	// New/re-enabled maps and edited profiles always get an initial refresh.
	if s.enabled {r3d.UpdateShadowMap(id)}
	ctx.scene_shadow_settings[entity]=s
}

// Request an update after moving a light or its casters when using manual mode.
// Call after the light has been synchronized at least once by the renderer.
request_shadow_update :: proc(ctx: ^Context, entity: ecs.Entity) -> bool {
	id,found:=ctx.scene_lights[entity]
	if !found || !r3d.IsLightExist(id) || !r3d.IsShadowEnabled(id) {return false}
	r3d.UpdateShadowMap(id)
	return true
}
