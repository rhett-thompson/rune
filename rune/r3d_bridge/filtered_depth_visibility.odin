package r3d_bridge

import "rune:assets"
import "rune:ecs"
import r3d "r3d:r3d"
import rl "vendor:raylib"

// Check that the current material and any retained GPU material preserve the
// mesh's authored positions. This lookup never loads an asset.
@(private)
material_preserves_mesh_bounds :: proc(ctx: ^Context, manager: ^assets.Asset_Manager, path: string) -> bool {
	if path == "" {
		material := r3d.GetDefaultMaterial()
		return material.shader == nil && material.billboardMode == .DISABLED
	}
	if manager == nil {return false}
	data, known := manager.material_previews[path]
	if !known {
		authored, found := manager.materials[path]
		if !found {return false}
		data = authored.data
	}
	if data.surface_shader != "" || (data.billboard != "" && data.billboard != "disabled") {return false}
	if cached, found := ctx.r3d_materials[path]; found {
		return cached.material.shader == nil && cached.material.billboardMode == .DISABLED
	}
	return true
}

@(private)
has_other_depth_renderer :: proc(world: ^ecs.World, entity: ecs.Entity) -> bool {
	_, sphere := ecs.get_sphere_renderer(world, entity)
	_, model := ecs.get_model_renderer(world, entity)
	_, terrain := ecs.get_terrain(world, entity)
	return sphere || model || terrain
}

@(private)
depth_stock_mesh :: proc(ctx: ^Context, mesh: ecs.MeshRenderer) -> ^r3d.Mesh {
	switch mesh.primitive {
	case "cube": return &ctx.cube if mesh.shadows else &ctx.cube_no_shadow
	case "plane": return &ctx.plane if mesh.shadows else &ctx.plane_no_shadow
	case "quad": return &ctx.quad if mesh.shadows else &ctx.quad_no_shadow
	case: return nil
	}
}

// An ordinary prop's stock bounds cannot stand in for a second renderer or
// for a material that can move vertices. Check the prepared bounds first so
// on-camera props avoid the extra component and material lookups.
@(private)
depth_stock_prop_outside_frustum :: proc(ctx: ^Context, world: ^ecs.World, manager: ^assets.Asset_Manager, entity: ecs.Entity, entry: ^Render_Entry, pass: Render_Pass, frustum: ^r3d.Frustum) -> bool {
	if frustum == nil || !entry.prepared {return false}
	mesh, found := ecs.get_mesh_renderer(world, entity)
	if !found || ((mesh.primitive == "plane") != (pass == .Plane_Only)) {return false}
	native_mesh := depth_stock_mesh(ctx, mesh)
	if native_mesh == nil || native_mesh.vertexCount <= 0 {return false}
	if frustum_may_intersect_box_at_pose(frustum, native_mesh.aabb, entry.pose, &entry.rotation) {return false}
	_, static_mesh := world.static_meshes[entity]
	return !static_mesh && !has_other_depth_renderer(world, entity) &&
		!ecs.has_component_data(world, entity, "CloudVolume") && material_preserves_mesh_bounds(ctx, manager, mesh.material)
}

// True if the installed static mesh's authored bounds cover this entity's
// rendered geometry. The caller supplies the current pose and its own bounds.
// Unavailable materials and renderers with unknown bounds fail open.
static_mesh_can_use_authored_bounds :: proc(ctx: ^Context, world: ^ecs.World, manager: ^assets.Asset_Manager, entity: ecs.Entity) -> bool {
	if ctx == nil || world == nil || !ecs.is_alive(world, entity) {return false}
	if _, installed := world.static_meshes[entity]; !installed {return false}
	mesh, found := ecs.get_mesh_renderer(world, entity)
	return found && mesh.primitive == "static" && !has_other_depth_renderer(world, entity) &&
		!ecs.has_component_data(world, entity, "CloudVolume") && material_preserves_mesh_bounds(ctx, manager, mesh.material)
}

@(private)
depth_excluded_geometry_may_intersect :: proc(ctx: ^Context, world: ^ecs.World, manager: ^assets.Asset_Manager, entity: ecs.Entity, frustum: ^r3d.Frustum) -> bool {
	if state, installed := world.static_meshes[entity]; installed {
		if !static_mesh_can_use_authored_bounds(ctx, world, manager, entity) {return true}
		cache, uploaded := ctx.static_meshes[entity]
		if !uploaded || ctx.static_mesh_generation != world.generation || cache.revision != state.revision {return true}
		pose, valid := ecs.terrain_transform(world, entity)
		return !valid || frustum_may_intersect_transformed_box(frustum, cache.mesh.aabb, pose)
	}
	if has_other_depth_renderer(world, entity) {return true}
	mesh, found := ecs.get_mesh_renderer(world, entity)
	if !found {return false}
	native_mesh := depth_stock_mesh(ctx, mesh)
	if native_mesh == nil {return mesh.primitive == "static"}
	if native_mesh.vertexCount <= 0 || !material_preserves_mesh_bounds(ctx, manager, mesh.material) {return true}
	return frustum_may_intersect_transformed_box(frustum, native_mesh.aabb, ecs.world_transform_3d(world, entity))
}

@(private)
depth_excluded_subtree_may_intersect :: proc(ctx: ^Context, world: ^ecs.World, manager: ^assets.Asset_Manager, entity: ecs.Entity, frustum: ^r3d.Frustum) -> bool {
	if !ecs.is_enabled(world, entity) {return false}
	if depth_excluded_geometry_may_intersect(ctx, world, manager, entity, frustum) {return true}
	for child in ecs.child_entities(world, entity) {
		if depth_excluded_subtree_may_intersect(ctx, world, manager, child, frustum) {return true}
	}
	return false
}

@(private)
depth_pass_exclusions_outside_frustum :: proc(ctx: ^Context, world: ^ecs.World, manager: ^assets.Asset_Manager, filter: Depth_Pass_Filter, frustum: ^r3d.Frustum) -> bool {
	if !occlusion_frustum_valid(frustum) {return false}
	for root in filter.ignored_subtrees {
		if depth_excluded_subtree_may_intersect(ctx, world, manager, root, frustum) {return false}
	}
	return true
}

@(private)
depth_pass_exclusions_outside_view :: proc(ctx: ^Context, world: ^ecs.World, manager: ^assets.Asset_Manager, filter: Depth_Pass_Filter, camera: rl.Camera3D, viewport: rl.Rectangle, framebuffer: [2]i32) -> bool {
	resolution: [2]i32
	r3d.GetResolution(&resolution[0], &resolution[1])
	main, auxiliary, known := scene_view_aspects(viewport, framebuffer, resolution, r3d.GetAspectMode())
	if !known {return false}
	frustum, valid := camera_frustum(camera, main)
	if !valid {return false}
	// The normal depth can substitute only when both views sample the same
	// projection. Casting a fitted viewport to float can perturb its aspect.
	if main != auxiliary {
		native := r3d.CameraFromRL(camera)
		if r3d.GetCameraProj(native, main) != r3d.GetCameraProj(native, auxiliary) {return false}
	}
	return depth_pass_exclusions_outside_frustum(ctx, world, manager, filter, &frustum)
}
