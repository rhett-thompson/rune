package r3d_bridge

import "core:path/filepath"
import "core:strings"
import r3d "r3d:r3d"
import "rune:assets"
import "rune:ecs"
import "rune:shadows"
import rl "vendor:raylib"

Scene3D_Settings :: struct {
	grid_slices:      i32,
	grid_spacing:     f32,
	draw_colliders:   bool,
	background_color: rl.Color,
}

Model_Asset :: struct {
	model:    r3d.Model,
	revision: u64,
	animations: r3d.AnimationLib,
	animations_loaded: bool,
	animations_attempted: bool,
	animation_sources_revision: u64,
}

R3D_Material_Asset :: struct {
	material:       r3d.Material,
	signature:      u64,
	asset_revision: u64,
	authored: bool,
	source_manager: ^assets.Asset_Manager,
	owns_albedo:    bool,
	owns_emission:  bool,
	owns_normal:    bool,
	owns_orm:       bool,
}

Context :: struct {
	instancing_enabled: bool,
	prop_batches: map[Prop_Batch_Key]Prop_Batch,
	prop_buffer_pool: [dynamic]r3d.InstanceBuffer,
	prop_sources: map[ecs.Entity]Prop_Source,
	prop_source_manager: ^assets.Asset_Manager,
	prop_material_revision: u64,
	prop_batches_ready: bool,
	gpu_timing_enabled: bool,
	gpu_timing: Gpu_Timing,
	// Compare material, primitive-render, and light caches against old behavior.
	render_optimizations_disabled: bool,
	render_cache: Render_Cache,
	light_properties: map[ecs.Entity]Light_Properties,
	light_sync_frame: u64,
	// Compare against the original per-mesh submission path when profiling.
	static_optimizations_disabled: bool,
	// Conservative CPU occlusion of static meshes/local lights; opt in per game.
	occlusion_enabled: bool,
	occlusion: Occlusion_State,
	frame_stats: Render_Stats,
	static_frame: u64,
	static_nodes: map[ecs.Entity]Static_Transform_Node,
	static_groups: map[ecs.Entity]Static_Draw_Group,
	// Master switch; does not mutate any authored light or profile settings.
	shadows_disabled: bool,
	scene_shadow_defaults: map[ecs.Entity]shadows.Settings,
	scene_shadow_settings: map[ecs.Entity]shadows.Settings,
	cloud_volumes: Cloud_Volume_Renderer,
	cloud_volumes_disabled: bool,
	static_meshes: map[ecs.Entity]Static_Mesh_Cache,
	static_mesh_generation: u32,
	detail_meshes: [3]r3d.Mesh,
	terrain_shaders: [3]^r3d.SurfaceShader,
	terrain_layers: map[string]Terrain_Layer_Asset,
	animation_sources: [dynamic]Model_Animation_Source,
	animation_source_version: u64,
	skybox: Skybox_Cache,
	terrains: map[ecs.Entity]Terrain_Cache,
	terrain_world_generation: u32,
	post_processing_active:   bool,
	post_processing_baseline: r3d.Environment,
	post_processing_aa:       r3d.AntiAliasingMode,
	height_fog_shader:        ^r3d.ScreenShader,
	height_fog_attempted:     bool,
	film_grain_shader: ^r3d.ScreenShader,
	film_grain_attempted: bool,
	light_shafts_shader: ^r3d.ScreenShader,
	light_shafts_attempted: bool,
	// Follow the window framebuffer by default; disable for a fixed internal resolution.
	match_framebuffer: bool,
	root:             string,
	cube:             r3d.Mesh,
	cube_no_shadow:   r3d.Mesh,
	plane:            r3d.Mesh,
	plane_no_shadow:  r3d.Mesh,
	quad:             r3d.Mesh,
	quad_no_shadow:   r3d.Mesh,
	sphere:           r3d.Mesh,
	sphere_no_shadow: r3d.Mesh,
	models:           map[string]Model_Asset,
	animation_players: map[ecs.Entity]Model_Player,
	animation_world_generation: u32,
	r3d_materials:    map[string]R3D_Material_Asset,
	retained_paths:   map[string]string,
	scene_lights:     map[ecs.Entity]r3d.Light,
	world_generation: u32,
	initialized:      bool,
}

is_available :: proc() -> bool {
	return true
}

init :: proc(root: string, width, height: i32) -> (Context, bool) {
	if !r3d.Init(width, height) {return {}, false}
	r3d.SetAntiAliasingMode(.FXAA)
	result := Context {
		scene_shadow_defaults = make(map[ecs.Entity]shadows.Settings),
		scene_shadow_settings = make(map[ecs.Entity]shadows.Settings),
		light_properties = make(map[ecs.Entity]Light_Properties),
		static_meshes = make(map[ecs.Entity]Static_Mesh_Cache),
		static_nodes = make(map[ecs.Entity]Static_Transform_Node),
		static_groups = make(map[ecs.Entity]Static_Draw_Group),
		terrain_layers = make(map[string]Terrain_Layer_Asset),
		match_framebuffer = true,
		terrains = make(map[ecs.Entity]Terrain_Cache),
		cube             = r3d.GenMeshCube(1, 1, 1),
		cube_no_shadow   = r3d.GenMeshCube(1, 1, 1),
		plane            = r3d.GenMeshPlane(1, 1, 1, 1),
		plane_no_shadow  = r3d.GenMeshPlane(1, 1, 1, 1),
		quad             = r3d.GenMeshQuad(1, 1, 1, 1, {0,0,1}),
		quad_no_shadow   = r3d.GenMeshQuad(1, 1, 1, 1, {0,0,1}),
		sphere           = r3d.GenMeshSphere(1, 24, 32),
		sphere_no_shadow = r3d.GenMeshSphere(1, 24, 32),
		models           = make(map[string]Model_Asset),
		animation_players = make(map[ecs.Entity]Model_Player),
		r3d_materials    = make(map[string]R3D_Material_Asset),
		retained_paths   = make(map[string]string),
		scene_lights     = make(map[ecs.Entity]r3d.Light),
		initialized      = true,
	}
	result.root = retain_path(&result, root)
	result.cube.shadowCastMode = .ON_DOUBLE_SIDED
	result.sphere.shadowCastMode = .ON_DOUBLE_SIDED
	result.cube_no_shadow.shadowCastMode = .DISABLED
	result.plane_no_shadow.shadowCastMode = .DISABLED
	result.quad.shadowCastMode = .ON_DOUBLE_SIDED
	result.quad_no_shadow.shadowCastMode = .DISABLED
	result.sphere_no_shadow.shadowCastMode = .DISABLED
	return result, true
}

shutdown :: proc(ctx: ^Context) {
	if !ctx.initialized {return}
	release_gpu_timing(ctx)
	release_render_cache(ctx)
	release_prop_buffer_pool(ctx)
	release_static_meshes(ctx)
	delete(ctx.static_meshes)
	delete(ctx.static_nodes)
	delete(ctx.static_groups)
	release_terrains(ctx)
	for mesh in ctx.detail_meshes {if r3d.IsMeshValid(mesh) {r3d.UnloadMesh(mesh)}}
	for shader in ctx.terrain_shaders {if shader!=nil {r3d.UnloadSurfaceShader(shader)}}
	for _, layer in ctx.terrain_layers {rl.UnloadTexture(layer.texture)}
	delete(ctx.terrain_layers)
	delete(ctx.terrains)
	release_skybox(ctx)
	release_cloud_volumes(ctx)
	if ctx.height_fog_shader != nil {r3d.UnloadScreenShader(ctx.height_fog_shader)}
	ctx.height_fog_shader = nil
	ctx.height_fog_attempted = false
	if ctx.film_grain_shader!=nil {r3d.UnloadScreenShader(ctx.film_grain_shader)}
	ctx.film_grain_shader=nil
	ctx.film_grain_attempted=false
	if ctx.light_shafts_shader!=nil {r3d.UnloadScreenShader(ctx.light_shafts_shader)}
	ctx.light_shafts_shader=nil
	ctx.light_shafts_attempted=false
	destroy_scene_lights(ctx)
	destroy_animation_players(ctx)
	for _, asset in ctx.models {
		if asset.animations_loaded {r3d.UnloadAnimationLib(asset.animations)}
		r3d.UnloadModel(asset.model, false)
	}
	for _, asset in ctx.r3d_materials {
		unload_owned_material_maps(asset)
	}
	if r3d.IsMeshValid(ctx.cube) {r3d.UnloadMesh(ctx.cube)}
	if r3d.IsMeshValid(ctx.cube_no_shadow) {r3d.UnloadMesh(ctx.cube_no_shadow)}
	if r3d.IsMeshValid(ctx.plane) {r3d.UnloadMesh(ctx.plane)}
	if r3d.IsMeshValid(ctx.plane_no_shadow) {r3d.UnloadMesh(ctx.plane_no_shadow)}
	if r3d.IsMeshValid(ctx.quad) {r3d.UnloadMesh(ctx.quad)}
	if r3d.IsMeshValid(ctx.quad_no_shadow) {r3d.UnloadMesh(ctx.quad_no_shadow)}
	if r3d.IsMeshValid(ctx.sphere) {r3d.UnloadMesh(ctx.sphere)}
	if r3d.IsMeshValid(ctx.sphere_no_shadow) {r3d.UnloadMesh(ctx.sphere_no_shadow)}
	delete(ctx.models)
	delete(ctx.animation_players)
	delete(ctx.animation_sources)
	delete(ctx.r3d_materials)
	delete(ctx.scene_lights)
	delete(ctx.scene_shadow_defaults)
	delete(ctx.scene_shadow_settings)
	delete(ctx.light_properties)
	destroy_retained_paths(ctx)
	r3d.Close()
	ctx^ = {}
}

draw_scene :: proc(
	ctx: ^Context,
	world: ^ecs.World,
	asset_manager: ^assets.Asset_Manager,
) -> bool {
	return draw_scene_ex(ctx, world, asset_manager, {})
}

draw_scene_ex :: proc(
	ctx: ^Context,
	world: ^ecs.World,
	asset_manager: ^assets.Asset_Manager,
	settings: Scene3D_Settings,
) -> bool {
	started:=rl.GetTime()
	ctx.frame_stats={}
	if !ctx.initialized {return false}
	prepare_gpu_timing(ctx)
	if ctx.match_framebuffer {
		width, height := rl.GetRenderWidth(), rl.GetRenderHeight()
		current_width, current_height: i32
		r3d.GetResolution(&current_width, &current_height)
		if width > 0 && height > 0 && (width != current_width || height != current_height) {
			r3d.SetResolution(width, height)
		}
	}
	prepare_terrains(ctx,world,asset_manager)
	prepare_static_meshes(ctx,world)
	prepare_animations(ctx, world, asset_manager, 0, false)
	entity, camera_component, found := ecs.active_camera_3d(world)
	apply_post_processing(ctx, world, entity)
	if !found {release_skybox(ctx); return false}
	transform, has_transform := ecs.get_transform(world, entity)
	if !has_transform {release_skybox(ctx); return false}

	camera := rl.Camera3D {
		position   = transform.position,
		target     = camera_component.target,
		up         = camera_component.up,
		fovy       = camera_component.fovy,
		projection = .PERSPECTIVE,
	}
	if ctx.world_generation != world.generation {
		destroy_scene_lights(ctx)
		ctx.world_generation = world.generation
	}
	apply_background(settings)
	apply_skybox(ctx, world, asset_manager, entity)
	apply_ambient(world)
	create_scene_lights(ctx, world, asset_manager)

	r3d.Begin(camera)
	prepare_cloud_volumes(ctx,world,asset_manager,camera)
	static_started:=rl.GetTime()
	draw_static_meshes(ctx,world,asset_manager,camera)
	ctx.frame_stats.static_cpu_ms=(rl.GetTime()-static_started)*1000
	cull_scene_lights(ctx)
	draw_terrains(ctx,world,asset_manager)
	draw_terrain_details(ctx,world,asset_manager,camera.position)
	if ctx.render_optimizations_disabled {
		for root in ecs.root_entities(world) {draw_entity_tree(ctx,world,asset_manager,root,identity_transform(),.Plane_Only)}
		for root in ecs.root_entities(world) {draw_entity_tree(ctx,world,asset_manager,root,identity_transform(),.Non_Plane)}
	} else {
		draw_cached_entities(ctx,world,asset_manager)
	}
	// The bridge owns SCENE while rendering; moon radiance is fogged too.
	chain: [3]^r3d.ScreenShader
	count: i32
	if prepare_moon_disk(ctx) {chain[count] = ctx.skybox.moon_shader; count += 1}
	if prepare_light_shafts(ctx,world,asset_manager,entity,camera) {chain[count]=ctx.light_shafts_shader; count+=1}
	if prepare_height_fog(ctx, world, asset_manager, entity) {chain[count] = ctx.height_fog_shader; count += 1}
	if count > 0 {r3d.SetScreenShaderChain(.SCENE, raw_data(chain[:]), count)}
	grain_enabled:=prepare_film_grain(ctx,world,asset_manager,entity)
	if grain_enabled {r3d.SetScreenShaderChain(.FINAL, &ctx.film_grain_shader, 1)}
	backend_started:=rl.GetTime()
	gpu_slot:=begin_gpu_timing(ctx)
	r3d.End()
	end_gpu_timing(ctx,gpu_slot)
	ctx.frame_stats.backend_cpu_ms=(rl.GetTime()-backend_started)*1000
	if count > 0 {r3d.SetScreenShaderChain(.SCENE, nil, 0)}
	if grain_enabled {r3d.SetScreenShaderChain(.FINAL, nil, 0)}
	draw_debug_overlays(world, camera, settings)
	ctx.frame_stats.scene_cpu_ms=(rl.GetTime()-started)*1000
	return true
}

Render_Pass :: enum {
	Plane_Only,
	Non_Plane,
}

draw_entity_tree :: proc(
	ctx: ^Context,
	world: ^ecs.World,
	asset_manager: ^assets.Asset_Manager,
	entity: ecs.Entity,
	parent: ecs.Transform,
	pass: Render_Pass,
) {
	if !ecs.is_enabled(world, entity) {return}
	local := parent
	if transform, has_transform := ecs.get_transform(world, entity); has_transform {
		local.position += transform.position
		local.rotation += transform.rotation
		local.scale *= transform.scale
	}
	draw_entity(ctx, world, asset_manager, entity, local, pass)
	for child in ecs.child_entities(world, entity) {
		draw_entity_tree(ctx, world, asset_manager, child, local, pass)
	}
}

draw_entity :: proc(
	ctx: ^Context,
	world: ^ecs.World,
	asset_manager: ^assets.Asset_Manager,
	entity: ecs.Entity,
	transform: ecs.Transform,
	pass: Render_Pass,
	render_matrix: ^rl.Matrix = nil,
) {
	if pass==.Non_Plane {draw_cloud_volume(ctx,world,entity,transform,render_matrix)}
	if mesh, has_mesh := ecs.get_mesh_renderer(world, entity);
	   has_mesh && mesh.primitive == "cube" {
		if pass != .Non_Plane {return}
		material := material_from_path(ctx, asset_manager, mesh.material, mesh.color)
		cube := ctx.cube if mesh.shadows else ctx.cube_no_shadow
		ctx.frame_stats.prop_draws+=1
		if render_matrix!=nil {
			r3d.DrawMeshPro(cube,material,render_matrix^)
		} else if is_unrotated(transform) && is_uniform_scale(transform.scale) {
			r3d.DrawMesh(cube, material, transform.position, transform.scale[0])
		} else {
			r3d.DrawMeshEx(
				cube,
				material,
				transform.position,
				rotation_quaternion(transform),
				transform.scale,
			)
		}
	}
	if mesh, has_mesh := ecs.get_mesh_renderer(world, entity);
	   has_mesh && mesh.primitive == "plane" {
		if pass != .Plane_Only {return}
		material := material_from_path(ctx, asset_manager, mesh.material, mesh.color)
		plane := ctx.plane if mesh.shadows else ctx.plane_no_shadow
		ctx.frame_stats.prop_draws+=1
		if render_matrix!=nil {
			r3d.DrawMeshPro(plane,material,render_matrix^)
		} else if is_unrotated(transform) && transform.scale[0] == transform.scale[2] {
			r3d.DrawMesh(plane, material, transform.position, transform.scale[0])
		} else {
			r3d.DrawMeshEx(
				plane,
				material,
				transform.position,
				rotation_quaternion(transform),
				transform.scale,
			)
		}
	}
	if mesh, has_mesh := ecs.get_mesh_renderer(world, entity);
	   has_mesh && mesh.primitive == "quad" {
		if pass != .Non_Plane {return}
		material := material_from_path(ctx, asset_manager, mesh.material, mesh.color)
		quad := ctx.quad if mesh.shadows else ctx.quad_no_shadow
		ctx.frame_stats.prop_draws+=1
		if render_matrix!=nil {r3d.DrawMeshPro(quad,material,render_matrix^)}
		else {r3d.DrawMeshEx(quad, material, transform.position, rotation_quaternion(transform), transform.scale)}
	}
	if sphere, has_sphere := ecs.get_sphere_renderer(world, entity); has_sphere {
		if pass != .Non_Plane {return}
		material := material_from_path(ctx, asset_manager, sphere.material, sphere.color)
		scale := transform.scale * sphere.radius
		sphere_mesh := ctx.sphere if sphere.shadows else ctx.sphere_no_shadow
		ctx.frame_stats.prop_draws+=1
		if render_matrix!=nil {
			r3d.DrawMeshPro(sphere_mesh,material,render_matrix^*rl.MatrixScale(sphere.radius,sphere.radius,sphere.radius))
		} else if is_unrotated(transform) && is_uniform_scale(scale) {
			r3d.DrawMesh(sphere_mesh, material, transform.position, scale[0])
		} else {
			r3d.DrawMeshEx(
				sphere_mesh,
				material,
				transform.position,
				rotation_quaternion(transform),
				scale,
			)
		}
	}
	if model_renderer, has_model := ecs.get_model_renderer(world, entity); has_model {
		if pass != .Non_Plane {return}
		loaded_model, loaded := load_model(ctx, asset_manager, model_renderer.model)
		if !loaded {return}
		apply_model_materials(ctx, asset_manager, &loaded_model, model_renderer)
		ctx.frame_stats.prop_draws+=int(loaded_model.meshCount)
		if animated, found := ctx.animation_players[entity]; found && animated.ready {
			if render_matrix!=nil {r3d.DrawAnimatedModelPro(loaded_model,animated.player,render_matrix^)}
			else {r3d.DrawAnimatedModelEx(loaded_model, animated.player, transform.position,
				rotation_quaternion(transform), transform.scale)}
		} else {
			if render_matrix!=nil {r3d.DrawModelPro(loaded_model,render_matrix^)}
			else {r3d.DrawModelEx(loaded_model, transform.position,
				rotation_quaternion(transform), transform.scale)}
		}
	}
}

apply_background :: proc(settings: Scene3D_Settings) {
	color := settings.background_color
	if color.a == 0 {
		color = rl.Color{8, 10, 14, 255}
	}
	env := r3d.GetEnvironment()
	env.background.color = color
	env.background.energy = 1
	env.background.sky = {}
	env.background.rotation = quaternion128(1)
}

apply_ambient :: proc(world: ^ecs.World) {
	color := rl.Color{46, 51, 61, 255}
	energy: f32 = 1
	for entity in ecs.entities_with_component(world, "AmbientLight") {
		light, found := ecs.get_ambient_light(world, entity)
		if !found {continue}
		color = to_raylib_color(light.color)
		energy = light.intensity
	}
	env := r3d.GetEnvironment()
	env.ambient.color = color
	env.ambient.energy = energy
}

create_scene_lights :: proc(ctx: ^Context, world: ^ecs.World, manager: ^assets.Asset_Manager = nil) {
	ctx.light_sync_frame+=1
	for entity, light in ctx.scene_lights {
		if !ecs.is_alive(world, entity) ||
		   (!ecs.has_component_data(world, entity, "DirectionalLight") &&
		    !ecs.has_component_data(world, entity, "PointLight") &&
		    !ecs.has_component_data(world, entity, "SpotLight")) {
			if r3d.IsLightExist(light) {r3d.DestroyLight(light)}
			delete_key(&ctx.scene_lights, entity)
			delete_key(&ctx.scene_shadow_defaults, entity)
			delete_key(&ctx.scene_shadow_settings, entity)
			delete_key(&ctx.light_properties, entity)
			continue
		}
		if ctx.render_optimizations_disabled {r3d.SetLightActive(light,false)}
	}
	for entity in ecs.entities_with_component(world, "DirectionalLight") {
		light, found := ecs.get_directional_light(world, entity)
		if !found {continue}
		if light.intensity <= 0 {continue}
		id := scene_light(ctx, entity, .DIR)
		sync_light_properties(ctx,entity,id,light)
		sync_light_shadows(ctx,manager,entity,id,light)
	}
	for entity in ecs.entities_with_component(world, "PointLight") {
		light, has_light := ecs.get_point_light(world, entity)
		transform, has_transform := ecs.get_transform(world, entity)
		if !has_light || !has_transform {continue}
		if light.intensity <= 0 {continue}
		id := scene_light(ctx, entity, .OMNI)
		sync_light_properties(ctx,entity,id,light,transform.position)
		sync_light_shadows(ctx,manager,entity,id,light)
	}
	for entity in ecs.entities_with_component(world, "SpotLight") {
		light, has_light := ecs.get_spot_light(world, entity)
		transform, has_transform := ecs.get_transform(world, entity)
		if !has_light || !has_transform {continue}
		if light.intensity <= 0 {continue}
		id := scene_light(ctx, entity, .SPOT)
		sync_light_properties(ctx,entity,id,light,transform.position)
		sync_light_shadows(ctx,manager,entity,id,light)
	}
	for e,id in ctx.scene_lights {
		properties:=ctx.light_properties[e]
		if properties.frame!=ctx.light_sync_frame && r3d.IsLightActive(id) {r3d.SetLightActive(id,false)}
	}
}

scene_light :: proc(ctx: ^Context, entity: ecs.Entity, light_type: r3d.LightType) -> r3d.Light {
	if id, found := ctx.scene_lights[entity]; found {
		if r3d.IsLightExist(id) && r3d.GetLightType(id) == light_type {
			return id
		}
		if r3d.IsLightExist(id) {
			r3d.DestroyLight(id)
		}
	}
	id := r3d.CreateLight(light_type)
	delete_key(&ctx.light_properties, entity)
	delete_key(&ctx.scene_shadow_settings, entity)
	ctx.scene_shadow_defaults[entity] = native_shadow_defaults(id)
	ctx.scene_lights[entity] = id
	return id
}

destroy_scene_lights :: proc(ctx: ^Context) {
	for entity, light in ctx.scene_lights {
		if r3d.IsLightExist(light) {
			r3d.DestroyLight(light)
		}
		delete_key(&ctx.scene_lights, entity)
		delete_key(&ctx.scene_shadow_defaults, entity)
		delete_key(&ctx.scene_shadow_settings, entity)
		delete_key(&ctx.light_properties, entity)
	}
}

load_model :: proc(
	ctx: ^Context,
	asset_manager: ^assets.Asset_Manager,
	path: string,
) -> (
	r3d.Model,
	bool,
) {
	if len(path) == 0 {return {}, false}
	revision, watched := assets.model_revision(asset_manager, path)
	if !watched {return {}, false}
	previous, already_loaded := ctx.models[path]
	if already_loaded && previous.revision == revision {return previous.model, true}
	full_path := resolve_path(ctx, path)
	cpath, _ := strings.clone_to_cstring(full_path)
	defer delete(cpath)
	loaded := import_model(cpath)
	if loaded.meshCount <= 0 {
		assets.report_failure(
			asset_manager,
			assets.Diagnostic {
				kind = .Model,
				operation = .Reload if already_loaded else .Load,
				field = "ModelRenderer.model",
				asset_path = path,
				detail = "r3d could not load the model; keeping the previous model" if already_loaded else "r3d could not load the model",
			},
		)
		if already_loaded {
			previous.revision = revision
			ctx.models[path] = previous
			return previous.model, true
		}
		return {}, false
	}
	assets.resolve_asset_failure(asset_manager, "", "ModelRenderer.model", path)
	animations: r3d.AnimationLib
	if already_loaded && previous.animations_loaded {
		animations = import_animation_set(ctx, asset_manager, path, loaded)
		if !animation_library_valid(loaded, animations) {
			r3d.UnloadAnimationLib(animations)
			r3d.UnloadModel(loaded, true)
			previous.revision = revision
			ctx.models[path] = previous
			report_animation_failure(asset_manager, path, "reloaded model has no compatible animations; keeping the previous model")
			return previous.model, true
		}
	}
	if already_loaded {
		invalidate_model_players(ctx, path)
		if previous.animations_loaded {r3d.UnloadAnimationLib(previous.animations)}
		r3d.UnloadModel(previous.model, false)
	}
	unload_imported_materials(&loaded)
	enable_model_shadows(&loaded)
	if already_loaded && previous.animations_loaded {
		assets.resolve_asset_failure(asset_manager, "", "ModelAnimator.clip", path)
	}
	ctx.models[retain_path(ctx, path)] = Model_Asset {
		model    = loaded,
		revision = revision,
		animations = animations,
		animations_loaded = already_loaded && previous.animations_loaded,
		animations_attempted = already_loaded && previous.animations_loaded,
		animation_sources_revision = animation_source_revision(ctx, asset_manager, path),
	}
	return loaded, true
}

unload_imported_materials :: proc(model: ^r3d.Model) {
	for index in 0 ..< model.materialCount {
		r3d.UnloadMaterial(model.materials[index])
		model.materials[index] = r3d.GetDefaultMaterial()
	}
}

enable_model_shadows :: proc(model: ^r3d.Model) {
	for index in 0 ..< model.meshCount {
		model.meshes[index].shadowCastMode = .ON_DOUBLE_SIDED
	}
}

apply_model_materials :: proc(
	ctx: ^Context,
	asset_manager: ^assets.Asset_Manager,
	model: ^r3d.Model,
	renderer: ecs.ModelRenderer,
) {
	if model.materialCount <= 0 {return}
	if _, loaded := assets.material_data(asset_manager, renderer.material); loaded {
		r3d_material := material_from_path(ctx, asset_manager, renderer.material, renderer.tint)
		for index in 0 ..< model.materialCount {
			model.materials[index] = r3d_material
		}
	} else {
		material := r3d.GetDefaultMaterial()
		material.albedo.color = to_raylib_color(renderer.tint)
		for index in 0 ..< model.materialCount {
			model.materials[index] = material
		}
	}
	for slot, path in renderer.materials {
		if slot < 0 || slot >= model.materialCount {continue}
		if _, loaded := assets.material_data(asset_manager, path); loaded {
			model.materials[slot] = material_from_path(ctx, asset_manager, path, renderer.tint)
		}
	}
}

material_from_path :: proc(
	ctx: ^Context,
	asset_manager: ^assets.Asset_Manager,
	path: string,
	fallback_color: ecs.Color,
) -> r3d.Material {
	ctx.frame_stats.material_requests+=1
	if !ctx.render_optimizations_disabled && path!="" {
		if cached,found:=ctx.r3d_materials[path]; found && cached.authored && cached.source_manager==asset_manager && cached.asset_revision==assets.material_asset_revision(asset_manager) {
			ctx.frame_stats.material_cache_hits+=1
			return cached.material
		}
	}
	if material, loaded := assets.material_data(asset_manager, path); loaded {
		result:=material_from_data(ctx, asset_manager, path, material)
		cached:=ctx.r3d_materials[path]; cached.authored=true; cached.source_manager=asset_manager
		ctx.r3d_materials[path]=cached
		return result
	}
	material := r3d.GetDefaultMaterial()
	material.albedo.color = to_raylib_color(fallback_color)
	return material
}

material_from_data :: proc(
	ctx: ^Context,
	asset_manager: ^assets.Asset_Manager,
	path: string,
	data: assets.Material_Data,
) -> r3d.Material {
	ctx.frame_stats.material_hashes+=1
	signature := material_signature(data)
	asset_revision := assets.material_asset_revision(asset_manager)
	if len(path) > 0 {
		if cached, found := ctx.r3d_materials[path]; found {
			if cached.signature == signature && cached.asset_revision == asset_revision {
				cached.authored=false; ctx.r3d_materials[path]=cached
				return cached.material
			}
			unload_owned_material_maps(cached)
		}
	}

	material := r3d.GetDefaultMaterial()
	material.albedo.color = rl.Color {
		data.base_color[0],
		data.base_color[1],
		data.base_color[2],
		data.base_color[3],
	}
	asset := R3D_Material_Asset {
		signature      = signature,
		asset_revision = asset_revision,
	}
	if asset_manager != nil && len(data.texture) > 0 {
		if albedo, loaded := load_albedo_map(ctx, data); loaded {
			material.albedo = albedo
			asset.owns_albedo = true
			assets.resolve_asset_failure(asset_manager, path, "$.albedo", data.texture)
		} else {
			assets.report_failure(
				asset_manager,
				assets.Diagnostic {
					kind = .Texture,
					operation = .Load,
					source_path = path,
					field = "$.albedo",
					asset_path = data.texture,
					detail = "r3d could not load the albedo map; using the material color",
				},
			)
		}
	}
	if asset_manager != nil && len(data.normal) > 0 {
		if normal, loaded := load_normal_map(ctx, data); loaded {
			material.normal = normal
			asset.owns_normal = true
			assets.resolve_asset_failure(asset_manager, path, "$.normal", data.normal)
		} else {
			assets.report_failure(
				asset_manager,
				assets.Diagnostic {
					kind = .Texture,
					operation = .Load,
					source_path = path,
					field = "$.normal",
					asset_path = data.normal,
					detail = "r3d could not load the normal map; using the default normal",
				},
			)
		}
	}
	material.normal.scale = data.normal_scale
	material.emission.color = rl.Color {
		data.emission_color[0],
		data.emission_color[1],
		data.emission_color[2],
		data.emission_color[3],
	}
	material.emission.energy = data.emission_energy
	if asset_manager != nil && len(data.emission) > 0 {
		if emission, loaded := load_emission_map(ctx, data); loaded {
			material.emission = emission
			asset.owns_emission = true
			assets.resolve_asset_failure(asset_manager, path, "$.emission", data.emission)
		} else {
			assets.report_failure(
				asset_manager,
				assets.Diagnostic {
					kind = .Texture,
					operation = .Load,
					source_path = path,
					field = "$.emission",
					asset_path = data.emission,
					detail = "r3d could not load the emission map; using the material emission color",
				},
			)
		}
	}
	has_orm_texture := false
	if asset_manager != nil && len(data.orm_texture) > 0 {
		if orm, loaded := load_orm_map(ctx, data); loaded {
			material.orm = orm
			has_orm_texture = true
			asset.owns_orm = true
			assets.resolve_asset_failure(asset_manager, path, "$.orm", data.orm_texture)
		} else {
			assets.report_failure(
				asset_manager,
				assets.Diagnostic {
					kind = .Texture,
					operation = .Load,
					source_path = path,
					field = "$.orm",
					asset_path = data.orm_texture,
					detail = "r3d could not load the ORM map; using scalar material values",
				},
			)
		}
	} else if asset_manager != nil {
		if orm, loaded := assets.material_orm_texture(asset_manager, data, path); loaded {
			material.orm.texture = orm
			has_orm_texture = true
		}
	}
	if has_orm_texture {
		material.orm.occlusion = data.ao_strength
	}
	if data.procedural.enabled && len(path) > 0 {
		apply_procedural_material(&material, &asset, data)
	}
	material.orm.roughness = data.roughness
	material.orm.metalness = data.metallic
	material.orm.specular = data.specular
	material.alphaCutoff = data.alpha_cutoff
	material.transparencyMode = transparency_mode_from_name(data.transparency)
	material.blendMode = blend_mode_from_name(data.blend)
	material.cullMode = cull_mode_from_name(data.cull)
	material.billboardMode = billboard_mode_from_name(data.billboard)
	material.unlit = !data.lighting
	asset.material = material
	if len(path) > 0 {
		ctx.r3d_materials[retain_path(ctx, path)] = asset
	}
	return material
}

material_signature :: proc(data: assets.Material_Data) -> u64 {
	return assets.material_data_signature(data)
}

retain_path :: proc(ctx: ^Context, path: string) -> string {
	if len(path) == 0 {return ""}
	if owned, found := ctx.retained_paths[path]; found {return owned}
	owned, _ := strings.clone(path)
	ctx.retained_paths[owned] = owned
	return owned
}

destroy_retained_paths :: proc(ctx: ^Context) {
	paths := make([dynamic]string)
	defer delete(paths)
	for path in ctx.retained_paths {append(&paths, path)}
	delete(ctx.retained_paths)
	ctx.retained_paths = nil
	for path in paths {delete(path)}
}

load_albedo_map :: proc(ctx: ^Context, data: assets.Material_Data) -> (r3d.AlbedoMap, bool) {
	full_path := resolve_path(ctx, data.texture)
	cpath, _ := strings.clone_to_cstring(full_path)
	defer delete(cpath)
	result := r3d.LoadAlbedoMap(
		cpath,
		rl.Color{data.base_color[0], data.base_color[1], data.base_color[2], data.base_color[3]},
	)
	if !rl.IsTextureValid(result.texture) {return {}, false}
	assets.configure_texture(&result.texture, data.filter, data.mipmaps)
	return result, true
}

load_normal_map :: proc(ctx: ^Context, data: assets.Material_Data) -> (r3d.NormalMap, bool) {
	full_path := resolve_path(ctx, data.normal)
	cpath, _ := strings.clone_to_cstring(full_path)
	defer delete(cpath)
	result := r3d.LoadNormalMap(cpath, data.normal_scale)
	if !rl.IsTextureValid(result.texture) {return {}, false}
	assets.configure_texture(&result.texture, data.filter, data.mipmaps)
	return result, true
}

load_emission_map :: proc(ctx: ^Context, data: assets.Material_Data) -> (r3d.EmissionMap, bool) {
	full_path := resolve_path(ctx, data.emission)
	cpath, _ := strings.clone_to_cstring(full_path)
	defer delete(cpath)
	result := r3d.LoadEmissionMap(
		cpath,
		rl.Color {
			data.emission_color[0],
			data.emission_color[1],
			data.emission_color[2],
			data.emission_color[3],
		},
		data.emission_energy,
	)
	if !rl.IsTextureValid(result.texture) {return {}, false}
	assets.configure_texture(&result.texture, data.filter, data.mipmaps)
	return result, true
}

load_orm_map :: proc(ctx: ^Context, data: assets.Material_Data) -> (r3d.OrmMap, bool) {
	full_path := resolve_path(ctx, data.orm_texture)
	cpath, _ := strings.clone_to_cstring(full_path)
	defer delete(cpath)
	result := r3d.LoadOrmMap(cpath, data.ao_strength, data.roughness, data.metallic, data.specular)
	if !rl.IsTextureValid(result.texture) {return {}, false}
	assets.configure_texture(&result.texture, data.filter, data.mipmaps)
	return result, true
}

unload_owned_material_maps :: proc(asset: R3D_Material_Asset) {
	if asset.owns_albedo {
		r3d.UnloadAlbedoMap(asset.material.albedo)
	}
	if asset.owns_emission {
		r3d.UnloadEmissionMap(asset.material.emission)
	}
	if asset.owns_normal {
		r3d.UnloadNormalMap(asset.material.normal)
	}
	if asset.owns_orm {
		r3d.UnloadOrmMap(asset.material.orm)
	}
}

transparency_mode_from_name :: proc(name: string) -> r3d.TransparencyMode {
	if name == "prepass" {return .PREPASS}
	if name == "alpha" {return .ALPHA}
	return .DISABLED
}

blend_mode_from_name :: proc(name: string) -> r3d.BlendMode {
	if name == "additive" {return .ADDITIVE}
	if name == "multiply" {return .MULTIPLY}
	if name == "premultiplied_alpha" {return .PREMULTIPLIED_ALPHA}
	return .MIX
}

cull_mode_from_name :: proc(name: string) -> r3d.CullMode {
	if name == "front" {return .FRONT}
	if name == "none" {return .NONE}
	return .BACK
}

billboard_mode_from_name :: proc(name: string) -> r3d.BillboardMode {
	if name == "front" {return .FRONT}
	if name == "y_axis" {return .Y_AXIS}
	return .DISABLED
}

draw_debug_overlays :: proc(world: ^ecs.World, camera: rl.Camera3D, settings: Scene3D_Settings) {
	if settings.grid_slices <= 0 && !settings.draw_colliders {return}
	rl.BeginMode3D(camera)
	if settings.grid_slices > 0 {
		spacing := settings.grid_spacing
		if spacing <= 0 {spacing = 1}
		rl.DrawGrid(settings.grid_slices, spacing)
	}
	if settings.draw_colliders {
		draw_collision_debug(world)
	}
	rl.EndMode3D()
}

draw_collision_debug :: proc(world: ^ecs.World) {
	for entity in ecs.entities_with_component(world, "BoxCollider") {
		collider, has_collider := ecs.get_box_collider(world, entity)
		transform, has_transform := ecs.get_transform(world, entity)
		if !has_collider || !has_transform {continue}
		half := [3]f32 {
			collider.size[0] * transform.scale[0] * 0.5,
			collider.size[1] * transform.scale[1] * 0.5,
			collider.size[2] * transform.scale[2] * 0.5,
		}
		box := rl.BoundingBox {
			min = transform.position - half,
			max = transform.position + half,
		}
		rl.DrawBoundingBox(box, rl.LIME if collider.is_static else rl.YELLOW)
	}
	for entity in ecs.entities_with_component(world, "SphereCollider") {
		collider, has_collider := ecs.get_sphere_collider(world, entity)
		transform, has_transform := ecs.get_transform(world, entity)
		if !has_collider || !has_transform {continue}
		scale := transform.scale[0]
		if transform.scale[1] > scale {scale = transform.scale[1]}
		if transform.scale[2] > scale {scale = transform.scale[2]}
		rl.DrawSphereWires(
			transform.position,
			collider.radius * scale,
			12,
			8,
			rl.LIME if collider.is_static else rl.YELLOW,
		)
	}
}

rotation_quaternion :: proc(transform: ecs.Transform) -> rl.Quaternion {
	return rl.QuaternionFromEuler(
		degrees_to_radians(transform.rotation[0]),
		degrees_to_radians(transform.rotation[1]),
		degrees_to_radians(transform.rotation[2]),
	)
}

is_unrotated :: proc(transform: ecs.Transform) -> bool {
	return transform.rotation[0] == 0 && transform.rotation[1] == 0 && transform.rotation[2] == 0
}

is_uniform_scale :: proc(scale: [3]f32) -> bool {
	return scale[0] == scale[1] && scale[1] == scale[2]
}

degrees_to_radians :: proc(value: f32) -> f32 {
	return value * 0.01745329252
}

resolve_path :: proc(ctx: ^Context, path: string) -> string {
	if filepath.is_abs(path) {return retain_path(ctx, path)}
	full_path, _ := filepath.join({ctx.root, path})
	owned := retain_path(ctx, full_path)
	delete(full_path)
	return owned
}

to_raylib_color :: proc(color: ecs.Color) -> rl.Color {
	return rl.Color{color.r, color.g, color.b, color.a}
}

identity_transform :: proc() -> ecs.Transform {
	return ecs.Transform{scale = {1, 1, 1}}
}
