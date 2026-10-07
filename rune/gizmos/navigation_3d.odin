package gizmos

import "rune:ecs"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

// Call inside an active 3D camera mode for games with custom camera rendering.
// Scene loops call this automatically through draw_scene. Meshes are borrowed
// each frame so reloads and runtime triangle blocking are immediately visible.
draw_navmeshes_3d :: proc(world: ^ecs.World, entity_id: string = "") {
	rlgl.DrawRenderBatchActive()
	rlgl.DisableDepthMask()
	defer {
		rlgl.DrawRenderBatchActive()
		rlgl.EnableDepthMask()
	}
	for entity in ecs.entities_with_component(world, "NavMesh3D") {
		if entity_id != "" {
			id, found := ecs.entity_id(world, entity)
			if !found || id != entity_id {continue}
		}
		mesh, ready := ecs.navigation_mesh_3d(world, entity)
		if !ready {continue}
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
}
