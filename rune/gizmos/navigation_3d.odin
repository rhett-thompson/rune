package gizmos

import "rune:ecs"
import "rune:navigation"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

// Call inside an active 3D camera mode for games with custom camera rendering.
// Scene loops call this automatically through draw_scene. Meshes are borrowed
// each frame so reloads and runtime triangle blocking are immediately visible.
// A nonzero runtime_entity overrides the scene ID. Unlike an ID filter, this
// handle cannot rebind to a different entity after scene replacement.
draw_navmeshes_3d :: proc(world: ^ecs.World, entity_id: string = "", runtime_entity: ecs.Entity = 0) {
	filter := runtime_entity
	if filter != 0 {
		if !ecs.is_alive(world, filter) {return}
	} else if entity_id != "" {
		found: bool
		filter, found = ecs.find_entity_by_id(world, entity_id)
		if !found {return}
	}
	for entity in ecs.entities_with_component(world, "NavMesh3D") {
		if filter != 0 && entity != filter {continue}
		mesh, ready := ecs.navigation_mesh_3d(world, entity)
		if ready {draw_navmesh_3d(mesh)}
	}
}

// Draw a game-owned or standalone mesh inside an active 3D camera mode. The
// mesh's world-space geometry is borrowed for this call, without registration,
// allocation, or ownership changes. Scene depth remains available for occlusion.
draw_navmesh_3d :: proc(mesh: navigation.Mesh_3D) {
	if len(mesh.triangles) == 0 {return}
	rlgl.DrawRenderBatchActive()
	rlgl.DisableDepthMask()
	defer {
		rlgl.DrawRenderBatchActive()
		rlgl.EnableDepthMask()
	}
	// Lift slightly off the collision surface to avoid coplanar flicker.
	offset := [3]f32{0, 0.02, 0}
	for triangle in mesh.triangles {
		a := mesh.vertices[triangle.vertices[0]] + offset
		b := mesh.vertices[triangle.vertices[1]] + offset
		c := mesh.vertices[triangle.vertices[2]] + offset
		fill := rl.Color{45, 180, 200, 75}
		edge := rl.Color{90, 220, 235, 220}
		if triangle.blocked {
			fill = {230, 65, 65, 100}
			edge = {255, 110, 100, 240}
		}
		rl.DrawTriangle3D(a, b, c, fill)
		rl.DrawTriangle3D(c, b, a, fill)
		rl.DrawLine3D(a, b, edge)
		rl.DrawLine3D(b, c, edge)
		rl.DrawLine3D(c, a, edge)
	}
}
