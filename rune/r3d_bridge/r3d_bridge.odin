package r3d_bridge

import "core:path/filepath"
import "core:fmt"
import "core:strings"
import "rune:assets"
import "rune:ecs"
import r3d "r3d:r3d"
import rl "vendor:raylib"

Scene3D_Settings :: struct {
	grid_slices:  i32,
	grid_spacing: f32,
	draw_colliders: bool,
	background_color: rl.Color,
}

Model_Asset :: struct {
	model: r3d.Model,
}

R3D_Material_Asset :: struct {
	material: r3d.Material,
	signature: string,
	owns_albedo: bool,
	owns_emission: bool,
	owns_normal: bool,
	owns_orm: bool,
}

Context :: struct {
	root: string,
	cube: r3d.Mesh,
	cube_no_shadow: r3d.Mesh,
	plane: r3d.Mesh,
	plane_no_shadow: r3d.Mesh,
	sphere: r3d.Mesh,
	sphere_no_shadow: r3d.Mesh,
	models: map[string]Model_Asset,
	r3d_materials: map[string]R3D_Material_Asset,
	scene_lights: map[ecs.Entity]r3d.Light,
	world_generation: u32,
	initialized: bool,
}

is_available :: proc() -> bool {
	return true
}

init :: proc(root: string, width, height: i32) -> (Context, bool) {
	if !r3d.Init(width, height) { return {}, false }
	r3d.SetAntiAliasingMode(.FXAA)
	result := Context{
		root = root,
		cube = r3d.GenMeshCube(1, 1, 1),
		cube_no_shadow = r3d.GenMeshCube(1, 1, 1),
		plane = r3d.GenMeshPlane(1, 1, 1, 1),
		plane_no_shadow = r3d.GenMeshPlane(1, 1, 1, 1),
		sphere = r3d.GenMeshSphere(1, 24, 32),
		sphere_no_shadow = r3d.GenMeshSphere(1, 24, 32),
		models = make(map[string]Model_Asset),
		r3d_materials = make(map[string]R3D_Material_Asset),
		scene_lights = make(map[ecs.Entity]r3d.Light),
		initialized = true,
	}
	result.cube.shadowCastMode = .ON_DOUBLE_SIDED
	result.sphere.shadowCastMode = .ON_DOUBLE_SIDED
	result.cube_no_shadow.shadowCastMode = .DISABLED
	result.plane_no_shadow.shadowCastMode = .DISABLED
	result.sphere_no_shadow.shadowCastMode = .DISABLED
	return result, true
}

shutdown :: proc(ctx: ^Context) {
	if !ctx.initialized { return }
	destroy_scene_lights(ctx)
	for _, asset in ctx.models {
		r3d.UnloadModel(asset.model, true)
	}
	for _, asset in ctx.r3d_materials {
		unload_owned_material_maps(asset)
	}
	if r3d.IsMeshValid(ctx.cube) { r3d.UnloadMesh(ctx.cube) }
	if r3d.IsMeshValid(ctx.cube_no_shadow) { r3d.UnloadMesh(ctx.cube_no_shadow) }
	if r3d.IsMeshValid(ctx.plane) { r3d.UnloadMesh(ctx.plane) }
	if r3d.IsMeshValid(ctx.plane_no_shadow) { r3d.UnloadMesh(ctx.plane_no_shadow) }
	if r3d.IsMeshValid(ctx.sphere) { r3d.UnloadMesh(ctx.sphere) }
	if r3d.IsMeshValid(ctx.sphere_no_shadow) { r3d.UnloadMesh(ctx.sphere_no_shadow) }
	delete(ctx.models)
	delete(ctx.r3d_materials)
	delete(ctx.scene_lights)
	r3d.Close()
	ctx.initialized = false
}

draw_scene :: proc(ctx: ^Context, world: ^ecs.World, asset_manager: ^assets.Asset_Manager) -> bool {
	return draw_scene_ex(ctx, world, asset_manager, {})
}

draw_scene_ex :: proc(ctx: ^Context, world: ^ecs.World, asset_manager: ^assets.Asset_Manager, settings: Scene3D_Settings) -> bool {
	if !ctx.initialized { return false }
	entity, camera_component, found := ecs.active_camera_3d(world)
	if !found { return false }
	transform, has_transform := ecs.get_transform(world, entity)
	if !has_transform { return false }

	camera := rl.Camera3D{
		position = transform.position,
		target = camera_component.target,
		up = camera_component.up,
		fovy = camera_component.fovy,
		projection = .PERSPECTIVE,
	}
	if ctx.world_generation != world.generation {
		destroy_scene_lights(ctx)
		ctx.world_generation = world.generation
	}
	apply_background(settings)
	apply_ambient(world)
	create_scene_lights(ctx, world)

	r3d.Begin(camera)
	for root in ecs.root_entities(world) {
		draw_entity_tree(ctx, world, asset_manager, root, identity_transform(), .Plane_Only)
	}
	for root in ecs.root_entities(world) {
		draw_entity_tree(ctx, world, asset_manager, root, identity_transform(), .Non_Plane)
	}
	r3d.End()
	draw_debug_overlays(world, camera, settings)
	return true
}

Render_Pass :: enum {
	Plane_Only,
	Non_Plane,
}

draw_entity_tree :: proc(ctx: ^Context, world: ^ecs.World, asset_manager: ^assets.Asset_Manager, entity: ecs.Entity, parent: ecs.Transform, pass: Render_Pass) {
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

draw_entity :: proc(ctx: ^Context, world: ^ecs.World, asset_manager: ^assets.Asset_Manager, entity: ecs.Entity, transform: ecs.Transform, pass: Render_Pass) {
	if mesh, has_mesh := ecs.get_mesh_renderer(world, entity); has_mesh && mesh.primitive == "cube" {
		if pass != .Non_Plane { return }
		material := material_from_path(ctx, asset_manager, mesh.material, mesh.color)
		cube := ctx.cube if mesh.shadows else ctx.cube_no_shadow
		if is_unrotated(transform) && is_uniform_scale(transform.scale) {
			r3d.DrawMesh(cube, material, transform.position, transform.scale[0])
		} else {
			r3d.DrawMeshEx(cube, material, transform.position, rotation_quaternion(transform), transform.scale)
		}
	}
	if mesh, has_mesh := ecs.get_mesh_renderer(world, entity); has_mesh && mesh.primitive == "plane" {
		if pass != .Plane_Only { return }
		material := material_from_path(ctx, asset_manager, mesh.material, mesh.color)
		plane := ctx.plane if mesh.shadows else ctx.plane_no_shadow
		if is_unrotated(transform) && transform.scale[0] == transform.scale[2] {
			r3d.DrawMesh(plane, material, transform.position, transform.scale[0])
		} else {
			r3d.DrawMeshEx(plane, material, transform.position, rotation_quaternion(transform), transform.scale)
		}
	}
	if sphere, has_sphere := ecs.get_sphere_renderer(world, entity); has_sphere {
		if pass != .Non_Plane { return }
		material := material_from_path(ctx, asset_manager, sphere.material, sphere.color)
		scale := transform.scale * sphere.radius
		sphere_mesh := ctx.sphere if sphere.shadows else ctx.sphere_no_shadow
		if is_unrotated(transform) && is_uniform_scale(scale) {
			r3d.DrawMesh(sphere_mesh, material, transform.position, scale[0])
		} else {
			r3d.DrawMeshEx(sphere_mesh, material, transform.position, rotation_quaternion(transform), scale)
		}
	}
	if model_renderer, has_model := ecs.get_model_renderer(world, entity); has_model {
		if pass != .Non_Plane { return }
		loaded_model, loaded := load_model(ctx, model_renderer.model)
		if !loaded { return }
		apply_model_materials(ctx, asset_manager, &loaded_model, model_renderer)
		r3d.DrawModelEx(loaded_model, transform.position, rotation_quaternion(transform), transform.scale)
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
}

apply_ambient :: proc(world: ^ecs.World) {
	color := rl.Color{46, 51, 61, 255}
	energy: f32 = 1
	for entity in ecs.entities_with_component(world, "AmbientLight") {
		light, found := ecs.get_ambient_light(world, entity)
		if !found { continue }
		color = to_raylib_color(light.color)
		energy = light.intensity
	}
	env := r3d.GetEnvironment()
	env.ambient.color = color
	env.ambient.energy = energy
}

create_scene_lights :: proc(ctx: ^Context, world: ^ecs.World) {
	for entity in ecs.entities_with_component(world, "DirectionalLight") {
		light, found := ecs.get_directional_light(world, entity)
		if !found { continue }
		if light.intensity <= 0 { continue }
		id := scene_light(ctx, entity, .DIR)
		r3d.SetLightDirection(id, light.direction)
		r3d.SetLightColor(id, to_raylib_color(light.color))
		r3d.SetLightEnergy(id, light.intensity)
		r3d.SetLightRange(id, light.range)
		r3d.SetLightSpecular(id, light.specular)
		r3d.SetLightActive(id, true)
		apply_shadow_settings(id, light.shadows, light.shadow_softness, light.shadow_opacity, light.shadow_depth_bias, light.shadow_slope_bias)
	}
	for entity in ecs.entities_with_component(world, "PointLight") {
		light, has_light := ecs.get_point_light(world, entity)
		transform, has_transform := ecs.get_transform(world, entity)
		if !has_light || !has_transform { continue }
		if light.intensity <= 0 { continue }
		id := scene_light(ctx, entity, .OMNI)
		r3d.SetLightPosition(id, transform.position)
		r3d.SetLightColor(id, to_raylib_color(light.color))
		r3d.SetLightEnergy(id, light.intensity)
		r3d.SetLightRange(id, light.range)
		r3d.SetLightSpecular(id, light.specular)
		r3d.SetLightActive(id, true)
		apply_shadow_settings(id, light.shadows, light.shadow_softness, light.shadow_opacity, light.shadow_depth_bias, light.shadow_slope_bias)
	}
	for entity in ecs.entities_with_component(world, "SpotLight") {
		light, has_light := ecs.get_spot_light(world, entity)
		transform, has_transform := ecs.get_transform(world, entity)
		if !has_light || !has_transform { continue }
		if light.intensity <= 0 { continue }
		id := scene_light(ctx, entity, .SPOT)
		r3d.LightLookAt(id, transform.position, transform.position + light.direction)
		r3d.SetLightColor(id, to_raylib_color(light.color))
		r3d.SetLightEnergy(id, light.intensity)
		r3d.SetLightRange(id, light.range)
		r3d.SetLightSpecular(id, light.specular)
		r3d.SetLightActive(id, true)
		apply_shadow_settings(id, light.shadows, light.shadow_softness, light.shadow_opacity, light.shadow_depth_bias, light.shadow_slope_bias)
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
	ctx.scene_lights[entity] = id
	return id
}

apply_shadow_settings :: proc(id: r3d.Light, enabled: bool, softness, opacity, depth_bias, slope_bias: f32) {
	if !enabled { return }
	r3d.EnableShadow(id)
	r3d.SetShadowOpacity(id, opacity)
	if softness > 0 {
		r3d.SetShadowSoftness(id, softness)
	}
	if depth_bias > 0 {
		r3d.SetShadowDepthBias(id, depth_bias)
	}
	if slope_bias > 0 {
		r3d.SetShadowSlopeBias(id, slope_bias)
	}
}

destroy_scene_lights :: proc(ctx: ^Context) {
	for entity, light in ctx.scene_lights {
		if r3d.IsLightExist(light) {
			r3d.DestroyLight(light)
		}
		delete_key(&ctx.scene_lights, entity)
	}
}

load_model :: proc(ctx: ^Context, path: string) -> (r3d.Model, bool) {
	if len(path) == 0 { return {}, false }
	if asset, found := ctx.models[path]; found { return asset.model, true }
	full_path := resolve_path(ctx.root, path)
	cpath, _ := strings.clone_to_cstring(full_path)
	defer delete(cpath)
	loaded := r3d.LoadModel(cpath)
	if loaded.meshCount <= 0 { return {}, false }
	enable_model_shadows(&loaded)
	ctx.models[path] = Model_Asset{model = loaded}
	return loaded, true
}

enable_model_shadows :: proc(model: ^r3d.Model) {
	for index in 0..<model.meshCount {
		model.meshes[index].shadowCastMode = .ON_DOUBLE_SIDED
	}
}

apply_model_materials :: proc(ctx: ^Context, asset_manager: ^assets.Asset_Manager, model: ^r3d.Model, renderer: ecs.ModelRenderer) {
	if model.materialCount <= 0 { return }
	if material, loaded := assets.material_data(asset_manager, renderer.material); loaded {
		r3d_material := material_from_data(ctx, asset_manager, renderer.material, material)
		for index in 0..<model.materialCount {
			model.materials[index] = r3d_material
		}
	} else {
		material := r3d.GetDefaultMaterial()
		material.albedo.color = to_raylib_color(renderer.tint)
		for index in 0..<model.materialCount {
			model.materials[index] = material
		}
	}
	for slot, path in renderer.materials {
		if slot < 0 || slot >= model.materialCount { continue }
		if material, loaded := assets.material_data(asset_manager, path); loaded {
			model.materials[slot] = material_from_data(ctx, asset_manager, path, material)
		}
	}
}

material_from_path :: proc(ctx: ^Context, asset_manager: ^assets.Asset_Manager, path: string, fallback_color: ecs.Color) -> r3d.Material {
	if material, loaded := assets.material_data(asset_manager, path); loaded {
		return material_from_data(ctx, asset_manager, path, material)
	}
	material := r3d.GetDefaultMaterial()
	material.albedo.color = to_raylib_color(fallback_color)
	return material
}

material_from_data :: proc(ctx: ^Context, asset_manager: ^assets.Asset_Manager, path: string, data: assets.Material_Data) -> r3d.Material {
	signature := material_signature(data)
	if len(path) > 0 {
		if cached, found := ctx.r3d_materials[path]; found {
			if cached.signature == signature {
				return cached.material
			}
			unload_owned_material_maps(cached)
		}
	}

	material := r3d.GetDefaultMaterial()
	material.albedo.color = rl.Color{data.base_color[0], data.base_color[1], data.base_color[2], data.base_color[3]}
	asset := R3D_Material_Asset{
		signature = signature,
	}
	if asset_manager != nil && len(data.texture) > 0 {
		if albedo, loaded := load_albedo_map(ctx, data); loaded {
			material.albedo = albedo
			asset.owns_albedo = true
		}
	}
	if asset_manager != nil && len(data.normal) > 0 {
		if normal, loaded := load_normal_map(ctx, data); loaded {
			material.normal = normal
			asset.owns_normal = true
		}
	}
	material.normal.scale = data.normal_scale
	material.emission.color = rl.Color{data.emission_color[0], data.emission_color[1], data.emission_color[2], data.emission_color[3]}
	material.emission.energy = data.emission_energy
	if asset_manager != nil && len(data.emission) > 0 {
		if emission, loaded := load_emission_map(ctx, data); loaded {
			material.emission = emission
			asset.owns_emission = true
		}
	}
	has_orm_texture := false
	if asset_manager != nil && len(data.orm_texture) > 0 {
		if orm, loaded := load_orm_map(ctx, data); loaded {
			material.orm = orm
			has_orm_texture = true
			asset.owns_orm = true
		}
	} else if asset_manager != nil {
		if orm, loaded := assets.material_orm_texture(asset_manager, data); loaded {
			material.orm.texture = orm
			has_orm_texture = true
		}
	}
	if has_orm_texture {
		material.orm.occlusion = data.ao_strength
	}
	material.orm.roughness = data.roughness
	material.orm.metalness = data.metallic
	material.orm.specular = data.specular
	material.alphaCutoff = data.alpha_cutoff
	material.transparencyMode = transparency_mode_from_name(data.transparency)
	material.blendMode = blend_mode_from_name(data.blend)
	material.cullMode = cull_mode_from_name(data.cull)
	material.unlit = !data.lighting
	asset.material = material
	if len(path) > 0 {
		ctx.r3d_materials[path] = asset
	}
	return material
}

material_signature :: proc(data: assets.Material_Data) -> string {
	return fmt.tprintf(
		"base=%v|albedo=%s|normal=%s|normal_scale=%f|emission=%s|emission_color=%v|emission_energy=%f|orm=%s|ao=%s|rough_map=%s|metal_map=%s|ao_strength=%f|rough=%f|metal=%f|spec=%f|alpha=%f|filter=%s|mips=%v|lighting=%v|trans=%s|blend=%s|cull=%s",
		data.base_color,
		data.texture,
		data.normal,
		data.normal_scale,
		data.emission,
		data.emission_color,
		data.emission_energy,
		data.orm_texture,
		data.ao_texture,
		data.roughness_texture,
		data.metallic_texture,
		data.ao_strength,
		data.roughness,
		data.metallic,
		data.specular,
		data.alpha_cutoff,
		data.filter,
		data.mipmaps,
		data.lighting,
		data.transparency,
		data.blend,
		data.cull,
	)
}

load_albedo_map :: proc(ctx: ^Context, data: assets.Material_Data) -> (r3d.AlbedoMap, bool) {
	full_path := resolve_path(ctx.root, data.texture)
	cpath, _ := strings.clone_to_cstring(full_path)
	defer delete(cpath)
	result := r3d.LoadAlbedoMap(cpath, rl.Color{data.base_color[0], data.base_color[1], data.base_color[2], data.base_color[3]})
	if !rl.IsTextureValid(result.texture) { return {}, false }
	assets.configure_texture(&result.texture, data.filter, data.mipmaps)
	return result, true
}

load_normal_map :: proc(ctx: ^Context, data: assets.Material_Data) -> (r3d.NormalMap, bool) {
	full_path := resolve_path(ctx.root, data.normal)
	cpath, _ := strings.clone_to_cstring(full_path)
	defer delete(cpath)
	result := r3d.LoadNormalMap(cpath, data.normal_scale)
	if !rl.IsTextureValid(result.texture) { return {}, false }
	assets.configure_texture(&result.texture, data.filter, data.mipmaps)
	return result, true
}

load_emission_map :: proc(ctx: ^Context, data: assets.Material_Data) -> (r3d.EmissionMap, bool) {
	full_path := resolve_path(ctx.root, data.emission)
	cpath, _ := strings.clone_to_cstring(full_path)
	defer delete(cpath)
	result := r3d.LoadEmissionMap(cpath, rl.Color{data.emission_color[0], data.emission_color[1], data.emission_color[2], data.emission_color[3]}, data.emission_energy)
	if !rl.IsTextureValid(result.texture) { return {}, false }
	assets.configure_texture(&result.texture, data.filter, data.mipmaps)
	return result, true
}

load_orm_map :: proc(ctx: ^Context, data: assets.Material_Data) -> (r3d.OrmMap, bool) {
	full_path := resolve_path(ctx.root, data.orm_texture)
	cpath, _ := strings.clone_to_cstring(full_path)
	defer delete(cpath)
	result := r3d.LoadOrmMap(cpath, data.ao_strength, data.roughness, data.metallic, data.specular)
	if !rl.IsTextureValid(result.texture) { return {}, false }
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
	if name == "prepass" { return .PREPASS }
	if name == "alpha" { return .ALPHA }
	return .DISABLED
}

blend_mode_from_name :: proc(name: string) -> r3d.BlendMode {
	if name == "additive" { return .ADDITIVE }
	if name == "multiply" { return .MULTIPLY }
	if name == "premultiplied_alpha" { return .PREMULTIPLIED_ALPHA }
	return .MIX
}

cull_mode_from_name :: proc(name: string) -> r3d.CullMode {
	if name == "front" { return .FRONT }
	if name == "none" { return .NONE }
	return .BACK
}

draw_debug_overlays :: proc(world: ^ecs.World, camera: rl.Camera3D, settings: Scene3D_Settings) {
	if settings.grid_slices <= 0 && !settings.draw_colliders { return }
	rl.BeginMode3D(camera)
	if settings.grid_slices > 0 {
		spacing := settings.grid_spacing
		if spacing <= 0 { spacing = 1 }
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
		if !has_collider || !has_transform { continue }
		half := [3]f32{
			collider.size[0] * transform.scale[0] * 0.5,
			collider.size[1] * transform.scale[1] * 0.5,
			collider.size[2] * transform.scale[2] * 0.5,
		}
		box := rl.BoundingBox{min = transform.position - half, max = transform.position + half}
		rl.DrawBoundingBox(box, rl.LIME if collider.is_static else rl.YELLOW)
	}
	for entity in ecs.entities_with_component(world, "SphereCollider") {
		collider, has_collider := ecs.get_sphere_collider(world, entity)
		transform, has_transform := ecs.get_transform(world, entity)
		if !has_collider || !has_transform { continue }
		scale := transform.scale[0]
		if transform.scale[1] > scale { scale = transform.scale[1] }
		if transform.scale[2] > scale { scale = transform.scale[2] }
		rl.DrawSphereWires(transform.position, collider.radius * scale, 12, 8, rl.LIME if collider.is_static else rl.YELLOW)
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

resolve_path :: proc(root, path: string) -> string {
	if filepath.is_abs(path) { return path }
	full_path, _ := filepath.join({root, path})
	return full_path
}

to_raylib_color :: proc(color: ecs.Color) -> rl.Color {
	return rl.Color{color.r, color.g, color.b, color.a}
}

identity_transform :: proc() -> ecs.Transform {
	return ecs.Transform{scale = {1, 1, 1}}
}
