package r3d_bridge

import "core:math"
import "core:strings"
import "rune:assets"
import "rune:ecs"
import r3d "r3d:r3d"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

// Borrowed entity roots omitted from an auxiliary scene-depth draw. This does
// not affect normal scene visibility, materials, lighting, or collision.
Depth_Pass_Filter :: struct {
	ignored_subtrees: []ecs.Entity,
}

// Caller-owned opaque pre-transparency linear depth, matching FetchDepth's
// material membership. Clear pixels contain the far distance.
// The target has native internal resolution and bottom-left texture coordinates.
Depth_Pass3D :: struct {
	target: rl.RenderTexture2D,
	copy_shader: rl.Shader,
	copy_attempted: bool,
	projection_location: i32,
	valid: bool,
	pass_count: u64,
}

// Stale roots are ignored. Disabled roots retain their exclusion meaning, but
// do not by themselves request a pass because their descendants do not draw.
depth_pass_excludes :: proc(world:^ecs.World,entity:ecs.Entity,filter:Depth_Pass_Filter) -> bool {
	if world==nil || !ecs.is_alive(world,entity) {return false}
	for root in filter.ignored_subtrees {
		if root==0 || !ecs.is_alive(world,root) {continue}
		for candidate:=entity;candidate!=0;candidate=world.parents[candidate] {
			if candidate==root {return true}
		}
	}
	return false
}

// No extra depth target or view when exclusions do not affect enabled geometry.
// Walk only requested subtrees, reusing the World's lazy hierarchy indexes.
depth_pass_filter_effective :: proc(world:^ecs.World,filter:Depth_Pass_Filter) -> bool {
	if world==nil || len(filter.ignored_subtrees)==0 {return false}
	for root in filter.ignored_subtrees {
		if depth_subtree_has_geometry(world,root) {return true}
	}
	return false
}

@(private)
depth_subtree_has_geometry :: proc(world:^ecs.World,entity:ecs.Entity) -> bool {
	if !ecs.is_enabled(world,entity) {return false}
	if mesh,found:=ecs.get_mesh_renderer(world,entity);found {
		switch mesh.primitive {case "cube","plane","quad","static":return true}
	}
	if _,found:=ecs.get_sphere_renderer(world,entity);found {return true}
	if _,found:=ecs.get_model_renderer(world,entity);found {return true}
	if _,found:=ecs.get_terrain(world,entity);found {return true}
	for child in ecs.child_entities(world,entity) {if depth_subtree_has_geometry(world,child) {return true}}
	return false
}

@(private)
depth_mark_subtree :: proc(world:^ecs.World,entity:ecs.Entity,excluded:^map[ecs.Entity]bool) {
	if !ecs.is_alive(world,entity) || excluded^[entity] {return}
	excluded^[entity]=true
	for child in ecs.child_entities(world,entity) {depth_mark_subtree(world,child,excluded)}
}

@(private)
load_depth_pass_target :: proc(width,height:i32) -> rl.RenderTexture2D {
	target:rl.RenderTexture2D
	target.id=rlgl.LoadFramebuffer()
	if target.id==0 {return {}}
	target.texture={id=rlgl.LoadTexture(nil,width,height,i32(rl.PixelFormat.UNCOMPRESSED_R32),1),width=width,height=height,mipmaps=1,format=.UNCOMPRESSED_R32}
	if target.texture.id==0 {rlgl.UnloadFramebuffer(target.id);return {}}
	rlgl.FramebufferAttach(target.id,target.texture.id,i32(rlgl.FramebufferAttachType.COLOR_CHANNEL0),i32(rlgl.FramebufferAttachTextureType.TEXTURE2D),0)
	if !rlgl.FramebufferComplete(target.id) {rl.UnloadRenderTexture(target);return {}}
	rl.SetTextureFilter(target.texture,.POINT)
	rl.SetTextureWrap(target.texture,.CLAMP)
	return target
}

// Call outside an active R3D session, after preparing terrain/static geometry
// and skeletal poses. Camera must be the full sampling camera for this draw.
// This uses ordinary material cutouts, vertex shaders, and composed transforms.
// It renders the same opaque membership used by screen shaders; ordinary unlit
// forward surfaces retain their existing non-occluding behavior in that buffer.
// Geometry hidden behind an excluded object is drawn into the new depth view;
// the ordinary scene depth and shader chains remain untouched after return.
render_scene_depth :: proc(view:^Depth_Pass3D,ctx:^Context,world:^ecs.World,manager:^assets.Asset_Manager,camera:rl.Camera3D,filter:Depth_Pass_Filter,material_time:f32) -> bool {
	return render_scene_depth_internal(view,ctx,world,manager,camera,filter,material_time,false)
}

@(private)
render_scene_depth_internal :: proc(view:^Depth_Pass3D,ctx:^Context,world:^ecs.World,manager:^assets.Asset_Manager,camera:rl.Camera3D,filter:Depth_Pass_Filter,material_time:f32,prepared:bool) -> bool {
	if view==nil {return false}
	view.valid=false
	if ctx==nil || !ctx.initialized || world==nil || active_render_view_3d || !depth_pass_filter_effective(world,filter) {return false}
	if math.is_nan(material_time) || math.is_inf(material_time) {return false}
	when !PRE_TRANSPARENCY_SHADERS_SUPPORTED {return false}
	width,height:i32
	r3d.GetResolution(&width,&height)
	if width<=0 || height<=0 {return false}
	near_distance,far_distance:=rlgl.GetCullDistanceNear(),rlgl.GetCullDistanceFar()
	if !(near_distance>0 && far_distance>near_distance) || math.is_inf(far_distance) {return false}
	if view.target.texture.width!=width || view.target.texture.height!=height {
		if view.target.id!=0 {rl.UnloadRenderTexture(view.target)}
		view.target=load_depth_pass_target(width,height)
	}
	if view.target.id==0 {return false}
	if !view.copy_attempted {
		view.copy_attempted=true
		source::#load("filtered_depth.glsl",string)
		view.copy_shader=rl.LoadShaderFromMemory(nil,strings.clone_to_cstring(source,context.temp_allocator))
		if view.copy_shader.id==rlgl.GetShaderIdDefault() {view.copy_shader={}}
		else {
			view.projection_location=rl.GetShaderLocation(view.copy_shader,"u_projection")
		}
	}
	if view.copy_shader.id==0 {return false}
	rlgl.DrawRenderBatchActive()
	if !begin_depth_capture() {return false}
	active_render_view_3d=true
	defer active_render_view_3d=false
	finished:=false
	defer if !finished {depth:rl.Texture2D;end_depth_capture(&depth)}
	saved_stats:=ctx.frame_stats
	defer ctx.frame_stats=saved_stats
	if !prepared {prepare_static_groups(ctx,world);prepare_render_cache(ctx,world)}
	excluded:=make(map[ecs.Entity]bool,context.temp_allocator)
	for root in filter.ignored_subtrees {depth_mark_subtree(world,root,&excluded)}
	r3d.BeginPro({camera=r3d.CameraFromRL(camera),target=view.target})
	// Reuse transforms and frustum clusters, but never normal CPU occlusion:
	// removing one occluder may expose architecture hidden in the main view.
	frustum:=r3d.GetFrustum()
	for _,group in ctx.static_groups {
		if !r3d.FrustumIntersectsBoundingBox(&frustum,group.bounds) {continue}
		r3d.BeginCluster(group.bounds)
		for entity in group.members {
			if excluded[entity] {continue}
			cache:=ctx.static_meshes[entity]
			submit_static_mesh(ctx,world,manager,entity,cache,cache.transform)
		}
		r3d.EndCluster()
	}
	draw_terrains(ctx,world,manager,filter)
	draw_terrain_details(ctx,world,manager,camera.position,filter)
	for entity in ctx.render_cache.planes {
		if excluded[entity] || !ctx.render_cache.nodes[entity].enabled {continue}
		entry:=ctx.render_cache.entries[entity]
		draw_entity(ctx,world,manager,entity,entry.pose,.Plane_Only,&entry.transform)
	}
	for entity in ctx.render_cache.others {
		if excluded[entity] || !ctx.render_cache.nodes[entity].enabled || ecs.has_component_data(world,entity,"CloudVolume") {continue}
		entry:=ctx.render_cache.entries[entity]
		draw_entity(ctx,world,manager,entity,entry.pose,.Non_Plane,&entry.transform)
	}
	update_material_shader_time(ctx,{material_time=material_time,material_time_override=true},f64(material_time))
	r3d.End()
	depth:rl.Texture2D
	captured:=end_depth_capture(&depth)
	finished=true
	if !captured || depth.id==0 || depth.width!=width || depth.height!=height {return false}
	// The native depth-only shader preserves cutouts and deformation. Convert
	// its hardware depth immediately, before the main view overwrites it.
	projection:=[3]f32{f32(near_distance),f32(far_distance),1 if camera.projection==.ORTHOGRAPHIC else 0}
	rl.SetShaderValue(view.copy_shader,view.projection_location,&projection,.VEC3)
	rl.BeginTextureMode(view.target)
	rl.BeginShaderMode(view.copy_shader)
	rlgl.DisableColorBlend()
	rl.DrawTexturePro(depth,{0,0,f32(width),-f32(height)},{0,0,f32(width),f32(height)},{},0,rl.WHITE)
	rlgl.DrawRenderBatchActive()
	rlgl.EnableColorBlend()
	rl.EndShaderMode()
	rl.EndTextureMode()
	view.valid=true
	view.pass_count+=1
	return true
}

destroy_depth_pass_3d :: proc(view:^Depth_Pass3D) {
	if view==nil {return}
	if view.target.id!=0 {rl.UnloadRenderTexture(view.target)}
	if view.copy_shader.id!=0 {rl.UnloadShader(view.copy_shader)}
	view^={}
}

when !PRE_TRANSPARENCY_SHADERS_SUPPORTED {
	@(private)
	begin_depth_capture :: proc() -> bool {return false}
	@(private)
	end_depth_capture :: proc(depth:^rl.Texture2D) -> bool {return false}
}
