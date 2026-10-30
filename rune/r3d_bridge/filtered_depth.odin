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
	far_location: i32,
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

// No allocation and no extra view when exclusions do not affect enabled
// rendered geometry. Plain organizational roots and disabled trees are cheap.
depth_pass_filter_effective :: proc(world:^ecs.World,filter:Depth_Pass_Filter) -> bool {
	if world==nil || len(filter.ignored_subtrees)==0 {return false}
	for entity in world.entities {
		if !ecs.is_enabled(world,entity) || !depth_pass_excludes(world,entity,filter) {continue}
		if mesh,found:=ecs.get_mesh_renderer(world,entity);found {
			switch mesh.primitive {case "cube","plane","quad","static":return true}
		}
		if _,found:=ecs.get_sphere_renderer(world,entity);found {return true}
		if _,found:=ecs.get_model_renderer(world,entity);found {return true}
		if _,found:=ecs.get_terrain(world,entity);found {return true}
	}
	return false
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
// It copies the same opaque linear depth used by screen shaders; ordinary unlit
// forward surfaces retain their existing non-occluding behavior in that buffer.
// Geometry hidden behind an excluded object is drawn into the new depth view;
// the ordinary scene depth and shader chains remain untouched after return.
render_scene_depth :: proc(view:^Depth_Pass3D,ctx:^Context,world:^ecs.World,manager:^assets.Asset_Manager,camera:rl.Camera3D,filter:Depth_Pass_Filter,material_time:f32) -> bool {
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
			view.far_location=rl.GetShaderLocation(view.copy_shader,"u_far_distance")
		}
	}
	if view.copy_shader.id==0 {return false}
	rlgl.DrawRenderBatchActive()
	if !begin_linear_view_capture(false) {return false}
	active_render_view_3d=true
	defer active_render_view_3d=false
	finished:=false
	defer if !finished {color,depth:rl.Texture2D;end_linear_view_capture(&color,&depth)}
	saved_environment:=r3d.GetEnvironment()^
	saved_aa:=r3d.GetAntiAliasingMode()
	saved_stats:=ctx.frame_stats
	defer {
		r3d.SetEnvironment(&saved_environment)
		r3d.SetAntiAliasingMode(saved_aa)
		ctx.frame_stats=saved_stats
	}
	environment:=r3d.ENVIRONMENT_BASE
	environment.background={color=rl.BLACK,energy=0}
	environment.ambient={color=rl.BLACK,energy=0}
	r3d.SetEnvironment(&environment)
	r3d.SetAntiAliasingMode(.NONE)
	r3d.BeginPro({camera=r3d.CameraFromRL(camera),target=view.target})
	// Never reuse CPU occlusion results from the normal view: an excluded mesh
	// may be the object that hid the architecture needed in this depth image.
	for entity,cache in ctx.static_meshes {
		if !ecs.is_enabled(world,entity) || depth_pass_excludes(world,entity,filter) {continue}
		pose,valid:=ecs.terrain_transform(world,entity)
		if valid {submit_static_mesh(ctx,world,manager,entity,cache,{},&pose)}
	}
	draw_terrains(ctx,world,manager,filter)
	draw_terrain_details(ctx,world,manager,camera.position,filter)
	for entity in world.entities {
		if !ecs.is_enabled(world,entity) || depth_pass_excludes(world,entity,filter) || ecs.has_component_data(world,entity,"CloudVolume") {continue}
		pose:=ecs.world_transform_3d(world,entity)
		draw_entity(ctx,world,manager,entity,pose,.Plane_Only)
		draw_entity(ctx,world,manager,entity,pose,.Non_Plane)
	}
	update_material_shader_time(ctx,{material_time=material_time,material_time_override=true},f64(material_time))
	r3d.End()
	color,raw_depth:rl.Texture2D
	captured:=end_linear_view_capture(&color,&raw_depth)
	finished=true
	if !captured {return false}
	// Raw final depth also includes opaque unlit forward surfaces. The linear
	// attachment instead matches the existing pre-transparency screen effects.
	// Despite the binding's older description, it already stores view-space Z.
	depth:=r3d.GetBufferDepth()
	if depth.id==0 || depth.width!=width || depth.height!=height {return false}
	// Native depth is borrowed and will be overwritten by the next Begin/End.
	// Copy now, before returning to the normal scene draw.
	far_value:=f32(far_distance)
	rl.SetShaderValue(view.copy_shader,view.far_location,&far_value,.FLOAT)
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
