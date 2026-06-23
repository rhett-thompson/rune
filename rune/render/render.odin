package render

import "rune:ecs"
import "rune:assets"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

// Rendering is intentionally a thin layer over raylib. r3d will live beside
// this package when the engine reaches its 3D milestone.
Renderer :: struct {
	clear_color: [4]u8,
}

// Scene3D_Settings holds presentation options owned by the renderer.
Scene3D_Settings :: struct {
	grid_slices:  i32,
	grid_spacing: f32,
	draw_colliders: bool,
}

init :: proc() -> Renderer {
	return Renderer{clear_color = {245, 245, 245, 255}}
}

// draw_scene_3d owns the raylib 3D mode boundary as well as entity rendering.
// Client code supplies engine data only; it never calls BeginMode3D/EndMode3D.
// draw_scene_3d renders through the active Camera3D entity. A camera needs a
// Transform for its position; target and up live on Camera3D itself.
draw_scene_3d :: proc(world: ^ecs.World, settings: Scene3D_Settings) -> bool {
	return draw_scene_3d_with_assets(world, nil, settings)
}

// draw_scene_3d_with_assets adds asset-backed ModelRenderer support while the
// original draw_scene_3d API remains useful for primitive-only scenes.
draw_scene_3d_with_assets :: proc(world: ^ecs.World, asset_manager: ^assets.Asset_Manager, settings: Scene3D_Settings) -> bool {
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
	rl.BeginMode3D(camera)
	if settings.grid_slices > 0 {
		spacing := settings.grid_spacing
		if spacing <= 0 { spacing = 1 }
		rl.DrawGrid(settings.grid_slices, spacing)
	}
	draw_world(world, asset_manager)
	if settings.draw_colliders { draw_collision_debug(world) }
	rl.EndMode3D()
	return true
}

// draw_scene_2d renders the sprite hierarchy through the active Camera2D.
// Sprite positions use the Transform X/Y plane; Z is currently ignored.
draw_scene_2d :: proc(world: ^ecs.World, asset_manager: ^assets.Asset_Manager) -> bool {
	entity, camera_component, found := ecs.active_camera_2d(world)
	if !found { return false }
	transform, has_transform := ecs.get_transform(world, entity)
	if !has_transform { return false }

	camera := rl.Camera2D{
		offset = camera_component.offset,
		target = {transform.position[0], transform.position[1]},
		rotation = camera_component.rotation,
		zoom = camera_component.zoom,
	}
	rl.BeginMode2D(camera)
	for root in ecs.root_entities(world) {
		draw_sprite_tree(world, asset_manager, root, {0, 0}, {1, 1}, 0)
	}
	rl.EndMode2D()
	return true
}

draw_sprite_tree :: proc(world: ^ecs.World, asset_manager: ^assets.Asset_Manager, entity: ecs.Entity, parent_position, parent_scale: [2]f32, parent_rotation: f32) {
	position := parent_position
	scale := parent_scale
	rotation := parent_rotation
	if transform, found := ecs.get_transform(world, entity); found {
		position += {transform.position[0] * parent_scale[0], transform.position[1] * parent_scale[1]}
		scale *= {transform.scale[0], transform.scale[1]}
		rotation += transform.rotation[2]
	}

	if sprite, found := ecs.get_sprite_renderer(world, entity); found {
		texture, _ := assets.texture(asset_manager, sprite.texture)
		source := rl.Rectangle{0, 0, f32(texture.width), f32(texture.height)}
		destination := rl.Rectangle{position[0], position[1], source.width * scale[0], source.height * scale[1]}
		origin := rl.Vector2{destination.width * sprite.origin[0], destination.height * sprite.origin[1]}
		rl.DrawTexturePro(texture, source, destination, origin, rotation, rl.WHITE)
	}

	for child in ecs.child_entities(world, entity) {
		draw_sprite_tree(world, asset_manager, child, position, scale, rotation)
	}
}

// draw_world owns render dispatch for scene entities. Each entity gets an
// isolated matrix scope, so game systems only update component data; they never
// need to pair PushMatrix/PopMatrix or issue renderer-specific draw calls.
draw_world :: proc(world: ^ecs.World, asset_manager: ^assets.Asset_Manager = nil) {
	for entity in ecs.root_entities(world) {
		draw_entity_tree(world, asset_manager, entity)
	}
}

draw_entity_tree :: proc(world: ^ecs.World, asset_manager: ^assets.Asset_Manager, entity: ecs.Entity) {
	rlgl.PushMatrix()
	if transform, has_transform := ecs.get_transform(world, entity); has_transform {
		apply_transform(transform)
	}

	draw_entity(world, asset_manager, entity)
	for child in ecs.child_entities(world, entity) {
		draw_entity_tree(world, asset_manager, child)
	}
	rlgl.PopMatrix()
}

apply_transform :: proc(transform: ecs.Transform) {
	rlgl.Translatef(transform.position[0], transform.position[1], transform.position[2])
	rlgl.Rotatef(transform.rotation[0], 1, 0, 0)
	rlgl.Rotatef(transform.rotation[1], 0, 1, 0)
	rlgl.Rotatef(transform.rotation[2], 0, 0, 1)
	rlgl.Scalef(transform.scale[0], transform.scale[1], transform.scale[2])
}

draw_entity :: proc(world: ^ecs.World, asset_manager: ^assets.Asset_Manager, entity: ecs.Entity) {
	if mesh, has_mesh := ecs.get_mesh_renderer(world, entity); has_mesh {
		if mesh.primitive == "cube" {
			rl.DrawCube({}, 1, 1, 1, to_raylib_color(mesh.color))
		}
	}
	if sphere, has_sphere := ecs.get_sphere_renderer(world, entity); has_sphere {
		rl.DrawSphere({}, sphere.radius, to_raylib_color(sphere.color))
	}
	if asset_manager != nil {
		if model_renderer, has_model := ecs.get_model_renderer(world, entity); has_model {
			if model, loaded := assets.model(asset_manager, model_renderer.model); loaded {
				rl.DrawModel(model, {}, 1, to_raylib_color(model_renderer.tint))
			}
		}
	}
}

to_raylib_color :: proc(color: ecs.Color) -> rl.Color {
	return rl.Color{color.r, color.g, color.b, color.a}
}

// draw_collision_debug renders BoxCollider bounds in the active 3D mode.
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
}
