package render

import "engine:ecs"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

// Rendering is intentionally a thin layer over raylib. r3d will live beside
// this package when the engine reaches its 3D milestone.
Renderer :: struct {
	clear_color: [4]u8,
}

// Camera3D is engine-facing camera data. Games do not need to import raylib's
// camera type to render a 3D scene.
Camera3D :: struct {
	position: [3]f32,
	target:   [3]f32,
	up:       [3]f32,
	fovy:     f32,
}

// Scene3D_Settings holds presentation options owned by the renderer.
Scene3D_Settings :: struct {
	camera:       Camera3D,
	grid_slices:  i32,
	grid_spacing: f32,
}

init :: proc() -> Renderer {
	return Renderer{clear_color = {245, 245, 245, 255}}
}

// draw_scene_3d owns the raylib 3D mode boundary as well as entity rendering.
// Client code supplies engine data only; it never calls BeginMode3D/EndMode3D.
draw_scene_3d :: proc(world: ^ecs.World, settings: Scene3D_Settings) {
	camera := rl.Camera3D{
		position = settings.camera.position,
		target = settings.camera.target,
		up = settings.camera.up,
		fovy = settings.camera.fovy,
		projection = .PERSPECTIVE,
	}
	rl.BeginMode3D(camera)
	if settings.grid_slices > 0 {
		spacing := settings.grid_spacing
		if spacing <= 0 { spacing = 1 }
		rl.DrawGrid(settings.grid_slices, spacing)
	}
	draw_world(world)
	rl.EndMode3D()
}

// draw_world owns render dispatch for scene entities. Each entity gets an
// isolated matrix scope, so game systems only update component data; they never
// need to pair PushMatrix/PopMatrix or issue renderer-specific draw calls.
draw_world :: proc(world: ^ecs.World) {
	for entity in ecs.root_entities(world) {
		draw_entity_tree(world, entity)
	}
}

draw_entity_tree :: proc(world: ^ecs.World, entity: ecs.Entity) {
	rlgl.PushMatrix()
	if transform, has_transform := ecs.get_transform(world, entity); has_transform {
		apply_transform(transform)
	}

	draw_entity(world, entity)
	for child in ecs.child_entities(world, entity) {
		draw_entity_tree(world, child)
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

draw_entity :: proc(world: ^ecs.World, entity: ecs.Entity) {
	if mesh, has_mesh := ecs.get_mesh_renderer(world, entity); has_mesh {
		if mesh.primitive == "cube" {
			rl.DrawCube({}, 1, 1, 1, to_raylib_color(mesh.color))
		}
	}
	if sphere, has_sphere := ecs.get_sphere_renderer(world, entity); has_sphere {
		rl.DrawSphere({}, sphere.radius, to_raylib_color(sphere.color))
	}
}

to_raylib_color :: proc(color: ecs.Color) -> rl.Color {
	return rl.Color{color.r, color.g, color.b, color.a}
}
