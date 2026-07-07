package r3d_bridge

import "core:path/filepath"
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

Context :: struct {
	root: string,
	cube: r3d.Mesh,
	sphere: r3d.Mesh,
	models: map[string]Model_Asset,
	frame_lights: [dynamic]r3d.Light,
	initialized: bool,
}

is_available :: proc() -> bool {
	return true
}

init :: proc(root: string, width, height: i32) -> (Context, bool) {
	if !r3d.Init(width, height) { return {}, false }
	r3d.SetAntiAliasingMode(.FXAA)
	r3d.SetTextureFilter(.ANISOTROPIC_8X)
	result := Context{
		root = root,
		cube = r3d.GenMeshCube(1, 1, 1),
		sphere = r3d.GenMeshSphere(1, 24, 32),
		models = make(map[string]Model_Asset),
		frame_lights = make([dynamic]r3d.Light),
		initialized = true,
	}
	return result, true
}

shutdown :: proc(ctx: ^Context) {
	if !ctx.initialized { return }
	clear_frame_lights(ctx)
	for _, asset in ctx.models {
		r3d.UnloadModel(asset.model, true)
	}
	if r3d.IsMeshValid(ctx.cube) { r3d.UnloadMesh(ctx.cube) }
	if r3d.IsMeshValid(ctx.sphere) { r3d.UnloadMesh(ctx.sphere) }
	delete(ctx.models)
	delete(ctx.frame_lights)
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

	clear_frame_lights(ctx)
	apply_background(settings)
	apply_ambient(world)
	create_scene_lights(ctx, world)

	r3d.Begin(camera)
	for root in ecs.root_entities(world) {
		draw_entity_tree(ctx, world, asset_manager, root, identity_transform())
	}
	r3d.End()
	draw_debug_overlays(world, camera, settings)
	return true
}

draw_entity_tree :: proc(ctx: ^Context, world: ^ecs.World, asset_manager: ^assets.Asset_Manager, entity: ecs.Entity, parent: ecs.Transform) {
	local := parent
	if transform, has_transform := ecs.get_transform(world, entity); has_transform {
		local.position += transform.position
		local.rotation += transform.rotation
		local.scale *= transform.scale
	}
	draw_entity(ctx, world, asset_manager, entity, local)
	for child in ecs.child_entities(world, entity) {
		draw_entity_tree(ctx, world, asset_manager, child, local)
	}
}

draw_entity :: proc(ctx: ^Context, world: ^ecs.World, asset_manager: ^assets.Asset_Manager, entity: ecs.Entity, transform: ecs.Transform) {
	if mesh, has_mesh := ecs.get_mesh_renderer(world, entity); has_mesh && mesh.primitive == "cube" {
		material := material_from_path(asset_manager, mesh.material, mesh.color)
		r3d.DrawMeshEx(ctx.cube, material, transform.position, rotation_quaternion(transform), transform.scale)
	}
	if sphere, has_sphere := ecs.get_sphere_renderer(world, entity); has_sphere {
		material := material_from_path(asset_manager, sphere.material, sphere.color)
		scale := transform.scale * sphere.radius
		r3d.DrawMeshEx(ctx.sphere, material, transform.position, rotation_quaternion(transform), scale)
	}
	if model_renderer, has_model := ecs.get_model_renderer(world, entity); has_model {
		loaded_model, loaded := load_model(ctx, model_renderer.model)
		if !loaded { return }
		apply_model_materials(asset_manager, &loaded_model, model_renderer)
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
		id := r3d.CreateLight(.DIR)
		r3d.SetLightDirection(id, light.direction)
		r3d.SetLightColor(id, to_raylib_color(light.color))
		r3d.SetLightEnergy(id, light.intensity)
		r3d.SetLightActive(id, true)
		append(&ctx.frame_lights, id)
	}
	for entity in ecs.entities_with_component(world, "PointLight") {
		light, has_light := ecs.get_point_light(world, entity)
		transform, has_transform := ecs.get_transform(world, entity)
		if !has_light || !has_transform { continue }
		id := r3d.CreateLight(.OMNI)
		r3d.SetLightPosition(id, transform.position)
		r3d.SetLightColor(id, to_raylib_color(light.color))
		r3d.SetLightEnergy(id, light.intensity)
		r3d.SetLightRange(id, light.range)
		r3d.SetLightAttenuation(id, 2)
		r3d.SetLightActive(id, true)
		append(&ctx.frame_lights, id)
	}
	for entity in ecs.entities_with_component(world, "SpotLight") {
		light, has_light := ecs.get_spot_light(world, entity)
		transform, has_transform := ecs.get_transform(world, entity)
		if !has_light || !has_transform { continue }
		id := r3d.CreateLight(.SPOT)
		r3d.SetLightPosition(id, transform.position)
		r3d.SetLightDirection(id, light.direction)
		r3d.SetLightColor(id, to_raylib_color(light.color))
		r3d.SetLightEnergy(id, light.intensity)
		r3d.SetLightRange(id, light.range)
		r3d.SetLightAttenuation(id, 2)
		r3d.SetLightInnerCutOff(id, light.inner_angle)
		r3d.SetLightOuterCutOff(id, light.outer_angle)
		r3d.SetLightActive(id, true)
		append(&ctx.frame_lights, id)
	}
}

clear_frame_lights :: proc(ctx: ^Context) {
	for light in ctx.frame_lights {
		if r3d.IsLightExist(light) {
			r3d.DestroyLight(light)
		}
	}
	clear(&ctx.frame_lights)
}

load_model :: proc(ctx: ^Context, path: string) -> (r3d.Model, bool) {
	if len(path) == 0 { return {}, false }
	if asset, found := ctx.models[path]; found { return asset.model, true }
	full_path := resolve_path(ctx.root, path)
	cpath, _ := strings.clone_to_cstring(full_path)
	defer delete(cpath)
	loaded := r3d.LoadModel(cpath)
	if loaded.meshCount <= 0 { return {}, false }
	ctx.models[path] = Model_Asset{model = loaded}
	return loaded, true
}

apply_model_materials :: proc(asset_manager: ^assets.Asset_Manager, model: ^r3d.Model, renderer: ecs.ModelRenderer) {
	if model.materialCount <= 0 { return }
	if material, loaded := assets.material_data(asset_manager, renderer.material); loaded {
		r3d_material := material_from_data(asset_manager, material)
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
			model.materials[slot] = material_from_data(asset_manager, material)
		}
	}
}

material_from_path :: proc(asset_manager: ^assets.Asset_Manager, path: string, fallback_color: ecs.Color) -> r3d.Material {
	if material, loaded := assets.material_data(asset_manager, path); loaded {
		return material_from_data(asset_manager, material)
	}
	material := r3d.GetDefaultMaterial()
	material.albedo.color = to_raylib_color(fallback_color)
	return material
}

material_from_data :: proc(asset_manager: ^assets.Asset_Manager, data: assets.Material_Data) -> r3d.Material {
	material := r3d.GetDefaultMaterial()
	material.albedo.color = rl.Color{data.base_color[0], data.base_color[1], data.base_color[2], data.base_color[3]}
	if asset_manager != nil && len(data.texture) > 0 {
		if texture, loaded := assets.material_texture(asset_manager, data.texture, data.filter, data.mipmaps); loaded {
			material.albedo.texture = texture
		}
	}
	if asset_manager != nil && len(data.normal) > 0 {
		if normal, loaded := assets.material_texture(asset_manager, data.normal, data.filter, data.mipmaps); loaded {
			material.normal.texture = normal
			material.normal.scale = 1
		}
	}
	has_orm_texture := false
	if asset_manager != nil {
		if orm, loaded := assets.material_orm_texture(asset_manager, data); loaded {
			material.orm.texture = orm
			has_orm_texture = true
		}
	}
	if has_orm_texture {
		material.orm.occlusion = 1
		material.orm.roughness = 1
		material.orm.metalness = 1
	} else {
		material.orm.roughness = data.roughness
		material.orm.metalness = data.metallic
	}
	material.unlit = !data.lighting
	return material
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
