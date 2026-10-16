package r3d_bridge

import "core:fmt"
import "core:math"
import "core:strings"
import "rune:assets"
import r3d "r3d:r3d"
import rl "vendor:raylib"

// A borrowed world-axis ellipsoid of moving air. Radius contains half extents;
// strength is a world-space displacement, phase is an animation offset in radians.
Distortion_Volume :: struct {
	position, radius: [3]f32,
	strength: f32,
	phase: f32,
}

Max_Distortion_Volumes :: 32

distortion_volume_bounds :: proc(v: Distortion_Volume) -> (rl.BoundingBox, bool) {
	for value in v.position {if math.is_nan(value) || math.is_inf(value) || abs(value)>1e12 {return {}, false}}
	for value in v.radius {if !(value>0.0001) || math.is_inf(value) || value>1e8 {return {}, false}}
	if !(v.strength>0) || math.is_inf(v.strength) || math.is_nan(v.phase) || math.is_inf(v.phase) {return {}, false}
	return {v.position-v.radius, v.position+v.radius}, true
}

// A fixed shortlist keeps both upload size and fragment work bounded. AABB
// frustum tests are conservative around ellipsoid edges and camera crossings.
select_distortion_volumes :: proc(volumes: []Distortion_Volume, camera: rl.Camera3D, frustum: ^r3d.Frustum, height: i32) -> (selected: [Max_Distortion_Volumes]Distortion_Volume, count: int) {
	if height<=0 {return}
	forward:=rl.Vector3Normalize(camera.target-camera.position)
	if rl.Vector3LengthSqr(forward)<0.5 {return}
	if camera.projection==.PERSPECTIVE && !perspective_angle_valid(camera.fovy) {return}
	if camera.projection==.ORTHOGRAPHIC && (!(camera.fovy>0) || math.is_inf(camera.fovy)) {return}
	distances: [Max_Distortion_Volumes]f32
	for volume in volumes {
		v:=volume
		bounds,valid:=distortion_volume_bounds(v)
		if !valid || !r3d.FrustumIntersectsBoundingBox(frustum,bounds) {continue}
		radius:=max(v.radius[0],max(v.radius[1],v.radius[2]))
		depth:=rl.Vector3DotProduct(v.position-camera.position,forward)
		if depth+radius<=0 {continue}
		pixels:=radius*f32(height)/camera.fovy
		if camera.projection==.PERSPECTIVE {
			pixels=radius*f32(height)/(2*max(depth-radius,0.0001)*math.tan(camera.fovy*f32(math.PI)/360))
		}
		if pixels<=0.5 {continue}
		// Fade before the half-pixel cutoff so distant effects do not pop.
		fade:=clamp((pixels-0.5)/1.5,0,1)
		v.strength*=fade*fade*(3-2*fade)
		distance:=rl.Vector3DistanceSqr(v.position,camera.position)
		index:=count
		if count==Max_Distortion_Volumes {
			if distance>=distances[count-1] {continue}
			index=count-1
		} else {count+=1}
		for index>0 && distance<distances[index-1] {
			selected[index]=selected[index-1]; distances[index]=distances[index-1]; index-=1
		}
		selected[index]=v; distances[index]=distance
	}
	return
}

// R3D's custom parser has sixteen uniforms and does not support arrays. Each
// mat4 carries two volumes in consecutive vec4 columns, without matrix math.
pack_distortion_volumes :: proc(volumes: []Distortion_Volume, time: f32) -> (packed: [16][4][4]f32) {
	clock:=time
	if math.is_nan(clock) || math.is_inf(clock) {clock=0}
	for v,index in volumes {
		if index>=Max_Distortion_Volumes {break}
		_,valid:=distortion_volume_bounds(v)
		if !valid {continue}
		phase:=f32(math.mod(f64(v.phase)+f64(clock)*2,2*math.PI))
		column:=(index%2)*2
		packed[index/2][column]={v.position[0],v.position[1],v.position[2],v.strength}
		packed[index/2][column+1]={1/v.radius[0],1/v.radius[1],1/v.radius[2],phase}
	}
	return
}

prepare_distortion :: proc(ctx: ^Context, manager: ^assets.Asset_Manager, settings: Scene3D_Settings, camera: rl.Camera3D) -> bool {
	if len(settings.distortion_volumes)==0 {return false}
	width,height: i32
	r3d.GetResolution(&width,&height)
	frustum:=r3d.GetFrustum()
	selected,count:=select_distortion_volumes(settings.distortion_volumes,camera,&frustum,height)
	if count==0 {return false}
	if !ctx.distortion_attempted {
		ctx.distortion_attempted=true
		source :: #load("distortion.glsl",string)
		ctx.distortion_shader=r3d.LoadScreenShaderFromMemory(strings.clone_to_cstring(source,context.temp_allocator))
		if ctx.distortion_shader==nil {
			assets.report_failure(manager,{kind=.PostProcessing,field="Scene3D_Settings.distortion_volumes",detail="could not load air distortion shader"})
		} else {assets.resolve_asset_failure(manager,"","Scene3D_Settings.distortion_volumes","")}
	}
	if ctx.distortion_shader==nil {return false}
	packed:=pack_distortion_volumes(selected[:count],material_shader_clock(settings,rl.GetTime()))
	for i in 0..<len(packed) {r3d.SetScreenShaderUniform(ctx.distortion_shader,fmt.ctprintf("u_volumes%d",i),&packed[i])}
	return true
}
