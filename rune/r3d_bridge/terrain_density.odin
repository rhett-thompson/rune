package r3d_bridge

import "core:math"
import "rune:terrain"

detail_density_enabled :: proc(detail:terrain.Detail) -> bool {
	return detail.density_distance[1]>detail.density_distance[0] && detail.density_min<1
}

// A source root keeps its dropout distance as the camera moves and packed slots
// change. The minimum-density subset survives until the ordinary draw cutoff.
detail_density_cutoff :: proc(detail:terrain.Detail,source:int) -> (fade_start,cutoff:f32) {
	if !detail_density_enabled(detail) {return math.inf_f32(1),math.inf_f32(1)}
	rank:=terrain.detail_random(u32(detail.seed),u32(source),5)
	if rank<detail.density_min {return math.inf_f32(1),math.inf_f32(1)}
	near,far:=detail.density_distance[0],detail.density_distance[1]
	cutoff=near+(1-rank)/(1-detail.density_min)*(far-near)
	fade_start=max(near,cutoff-min(f32(2),(far-near)*0.1))
	return
}

// Shrink only the roots about to leave the selection. Outside that short band,
// the conservative movement proof lets static instance streams remain cached.
detail_density_visibility :: proc(fade_start,cutoff,distance,margin:f32) -> (scale,reuse_radius:f32) {
	reuse_radius=min(abs(distance-fade_start),abs(distance-cutoff))-margin
	if distance>=cutoff {return 0,reuse_radius}
	if distance<=fade_start {return 1,reuse_radius}
	fraction:=clamp((cutoff-distance)/(cutoff-fade_start),0,1)
	return fraction*fraction*(3-2*fraction),0
}
