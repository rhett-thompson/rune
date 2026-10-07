package r3d_bridge

import "core:math"
import "core:strings"
import "rune:assets"
import "rune:ecs"
import r3d "r3d:r3d"
import rl "vendor:raylib"

// Match the bridge's additive parent positions. Resolve the stable ID every
// frame so regeneration and scene reload never retain an obsolete handle.
light_shaft_source :: proc(world:^ecs.World,id:string) -> ([3]f32,bool) {
	entity,found:=ecs.find_entity_by_id(world,id)
	if !found || !ecs.is_enabled(world,entity) {return {},false}
	transform,has_transform:=ecs.get_transform(world,entity)
	if !has_transform {return {},false}
	position:=transform.position
	for {
		parent,has_parent:=ecs.get_parent(world,entity)
		if !has_parent {break}
		if pose,ok:=ecs.get_transform(world,parent); ok {position+=pose.position}
		entity=parent
	}
	return position,ecs.physics_query_vector_valid(position)
}

prepare_light_shafts :: proc(ctx:^Context,world:^ecs.World,manager:^assets.Asset_Manager,camera_entity:ecs.Entity,camera:rl.Camera3D) -> bool {
	profile,found:=ecs.active_post_processing(world,camera_entity)
	if !found || !profile.light_shafts.enabled || profile.light_shafts.intensity<=0 {return false}
	v:=profile.light_shafts
	position,valid:=light_shaft_source(world,v.source)
	if !valid {return false}
	forward:=rl.Vector3Normalize(camera.target-camera.position)
	depth:=rl.Vector3DotProduct(position-camera.position,forward)
	if depth<=v.source_radius {return false}
	width,height:i32
	r3d.GetResolution(&width,&height)
	if width<=0 || height<=0 {return false}
	pixel:=rl.GetWorldToScreenEx(position,camera,width,height)
	source:=[3]f32{pixel[0]/f32(width),1-pixel[1]/f32(height),depth}
	// Fade over the outer tenth of the viewport; discard well off-screen.
	edge:=max(max(-source[0],source[0]-1),max(-source[1],source[1]-1))
	if edge>=0.1 {return false}
	fade:=1-clamp(edge/0.1,0,1)
	fade=fade*fade*(3-2*fade)
	if !ctx.light_shafts_attempted {
		ctx.light_shafts_attempted=true
		source_text::#load("light_shafts.glsl",string)
		ctx.light_shafts_shader=r3d.LoadScreenShaderFromMemory(strings.clone_to_cstring(source_text,context.temp_allocator))
		if ctx.light_shafts_shader==nil {
			assets.report_failure(manager,{kind=.PostProcessing,field="PostProcessing.light_shafts",detail="could not load light shaft shader"})
		} else {assets.resolve_asset_failure(manager,"","PostProcessing.light_shafts","")}
	}
	shader:=ctx.light_shafts_shader
	if shader==nil {return false}
	color:[3]f32
	for i in 0..<3 {color[i]=math.pow(f32(v.color[i])/255,2.2)}
	settings:=[4]f32{v.intensity,v.radius,v.source_radius,f32(width)/f32(height)}
	resolution:=[2]f32{f32(width),f32(height)}
	disk:=v.source_radius/(depth*math.tan(camera.fovy*f32(math.PI)/360)*2)
	if camera.projection==.ORTHOGRAPHIC {disk=v.source_radius/camera.fovy}
	r3d.SetScreenShaderUniform(shader,"u_source",&source)
	r3d.SetScreenShaderUniform(shader,"u_color",&color)
	r3d.SetScreenShaderUniform(shader,"u_settings",&settings)
	r3d.SetScreenShaderUniform(shader,"u_disk_radius",&disk)
	r3d.SetScreenShaderUniform(shader,"u_edge_fade",&fade)
	r3d.SetScreenShaderUniform(shader,"u_samples",&v.samples)
	r3d.SetScreenShaderUniform(shader,"u_resolution",&resolution)
	return true
}
