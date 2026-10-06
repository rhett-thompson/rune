package r3d_bridge

import "core:math"
import r3d "r3d:r3d"
import rl "vendor:raylib"

// A range sphere contains both point and spot lighting. Using its box for
// spots deliberately retains more lights than testing their narrower cones.
// Read current position/range: R3D's cached light AABB updates during End().
light_influence_bounds :: proc(position:rl.Vector3,range:f32) -> (rl.BoundingBox,bool) {
	if !(range>0) || math.is_inf(range) {return {},false}
	for value in position {if math.is_nan(value) || math.is_inf(value) {return {},false}}
	bounds:=rl.BoundingBox{position-rl.Vector3{range,range,range},position+rl.Vector3{range,range,range}}
	for axis in 0..<3 {
		bounds.min[axis]-=0.001; bounds.max[axis]+=0.001
		if math.is_inf(bounds.min[axis]) || math.is_inf(bounds.max[axis]) {return {},false}
	}
	return bounds,true
}

cull_scene_lights :: proc(ctx:^Context) {
	started:=rl.GetTime()
	active:=ctx.occlusion_enabled && !ctx.static_optimizations_disabled && ctx.occlusion.prepared
	for _,id in ctx.scene_lights {
		if !r3d.IsLightActive(id) || r3d.GetLightType(id)==.DIR {continue}
		ctx.frame_stats.local_lights+=1
		if !active {continue}
		bounds,valid:=light_influence_bounds(r3d.GetLightPosition(id),r3d.GetLightRange(id))
		if !valid {continue}
		ctx.frame_stats.light_occlusion_tests+=1
		if !bounds_occluded(bounds,&ctx.occlusion) {continue}
		r3d.SetLightActive(id,false)
		ctx.frame_stats.local_lights_occluded+=1
		if r3d.IsShadowEnabled(id) {
			ctx.frame_stats.local_shadow_lights_occluded+=1
			// Disabled lights do no shadow work. Leave a refresh pending so an
			// interval/manual map is current when this light becomes visible.
			r3d.UpdateShadowMap(id)
		}
	}
	ctx.frame_stats.light_occlusion_cpu_ms=(rl.GetTime()-started)*1000
}
