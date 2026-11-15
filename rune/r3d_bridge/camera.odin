package r3d_bridge

import "core:math"
import "rune:ecs"
import r3d "r3d:r3d"
import rl "vendor:raylib"

// Camera origins follow the rendered hierarchy. Target and up remain explicit
// world-space vectors, independent of the entity's rotation and scale.
scene_camera_3d :: proc(world:^ecs.World,entity:ecs.Entity,value:ecs.Camera3D) -> (rl.Camera3D,bool) {
	_,has_transform:=ecs.get_transform(world,entity)
	if !has_transform {return {},false}
	return rl.Camera3D{
		position=ecs.world_transform_3d(world,entity).position,
		target=value.target,
		up=value.up,
		fovy=value.fovy,
		projection=rl.CameraProjection(value.projection),
	},true
}

// A conservative pre-draw frustum enclosing the main scene and its auxiliary
// depth view. Use current poses and the same sampling FOV supplied to draw_scene.
// A failed lookup leaves the caller's visibility decision open.
scene_sampling_frustum :: proc(ctx: ^Context, world: ^ecs.World, sampling_fovy: f32) -> (r3d.Frustum, bool) {
	if ctx == nil || !ctx.initialized || world == nil {return {}, false}
	entity, settings, found := ecs.active_camera_3d(world)
	if !found {return {}, false}
	camera, valid := scene_camera_3d(world, entity, settings)
	if !valid {return {}, false}
	framebuffer := [2]i32{rl.GetRenderWidth(), rl.GetRenderHeight()}
	sampling_camera, viewport, _ := scene_sampling_projection(camera, sampling_fovy, framebuffer)
	resolution: [2]i32
	if ctx.match_framebuffer {resolution = scaled_framebuffer_dimensions(framebuffer, ctx.render_scale)}
	else {r3d.GetResolution(&resolution[0], &resolution[1])}
	main, auxiliary, available := scene_view_aspects(viewport, framebuffer, resolution, r3d.GetAspectMode())
	if !available {return {}, false}
	return camera_frustum(sampling_camera, max(main, auxiliary))
}

@(private)
scene_view_aspects :: proc(viewport: rl.Rectangle, framebuffer, resolution: [2]i32, aspect_mode: r3d.AspectMode) -> (main, auxiliary: f64, valid: bool) {
	if framebuffer[0] <= 0 || framebuffer[1] <= 0 || resolution[0] <= 0 || resolution[1] <= 0 {return}
	auxiliary = f64(resolution[0]) / f64(resolution[1])
	width, height := f32(framebuffer[0]), f32(framebuffer[1])
	if viewport.width > 0 && viewport.height > 0 {width, height = viewport.width, viewport.height}
	switch aspect_mode {
	case .KEEP:
		// The native renderer rounds the fitted viewport back to f32 before
		// taking its aspect ratio for projection.
		if auxiliary > f64(width)/f64(height) {height = f32(f64(width)/auxiliary)}
		else {width = f32(f64(height)*auxiliary)}
	case .EXPAND:
	case:
		return 0, 0, false
	}
	return f64(width)/f64(height), auxiliary, true
}

@(private)
camera_frustum :: proc(camera: rl.Camera3D, aspect: f64) -> (r3d.Frustum, bool) {
	if !(aspect > 0) || math.is_inf(aspect) || !scene_query_vector_valid(camera.position) ||
	   !scene_query_vector_valid(camera.target) || !scene_query_vector_valid(camera.up) {return {}, false}
	forward, forward_valid := scene_query_unit(camera.target-camera.position)
	if !forward_valid {return {}, false}
	if _, right_valid := scene_query_unit(rl.Vector3CrossProduct(forward, camera.up)); !right_valid {return {}, false}
	switch camera.projection {
	case .PERSPECTIVE:
		if !perspective_angle_valid(camera.fovy) {return {}, false}
	case .ORTHOGRAPHIC:
		if !(camera.fovy > 0) || math.is_inf(camera.fovy) {return {}, false}
	case:
		return {}, false
	}
	native := r3d.CameraFromRL(camera)
	if !(native.nearPlane > 0 && native.farPlane > native.nearPlane) || math.is_inf(native.farPlane) {return {}, false}
	frustum := r3d.ComputeFrustum(r3d.GetCameraViewProj(native, aspect))
	return frustum, occlusion_frustum_valid(&frustum)
}

// Test an undeformed local box under the given render pose. Keep a small pad
// for clipping-plane arithmetic and fail open on unknown or invalid bounds.
frustum_may_intersect_transformed_box :: proc(frustum: ^r3d.Frustum, local: rl.BoundingBox, pose: ecs.Transform) -> bool {
	return frustum_may_intersect_box_at_pose(frustum, local, pose)
}

@(private)
frustum_may_intersect_box_at_pose :: proc(frustum: ^r3d.Frustum, local: rl.BoundingBox, pose: ecs.Transform, cached_rotation: ^rl.Quaternion = nil) -> bool {
	if frustum == nil || !ecs.component_value_valid(pose) ||
	   !scene_query_vector_valid(local.min) || !scene_query_vector_valid(local.max) {return true}
	for axis in 0..<3 {if local.min[axis] > local.max[axis] {return true}}
	rotation := cached_rotation^ if cached_rotation != nil else rotation_quaternion(pose)
	center := pose.position + rl.Vector3RotateByQuaternion((local.min+local.max)*0.5*pose.scale, rotation)
	scale := [3]f32{abs(pose.scale[0]), abs(pose.scale[1]), abs(pose.scale[2])}
	half := (local.max-local.min)*0.5*scale
	if !scene_query_vector_valid(center) || !scene_query_vector_valid(half) {return true}
	magnitude := max(abs(center[0]), abs(center[1]), abs(center[2]), half[0], half[1], half[2])
	pad := 0.01+magnitude*0.000004
	half += [3]f32{pad, pad, pad}
	box := r3d.OrientedBox {
		center = center, halfExtents = half,
		axisX = rl.Vector3RotateByQuaternion({1,0,0}, rotation),
		axisY = rl.Vector3RotateByQuaternion({0,1,0}, rotation),
		axisZ = rl.Vector3RotateByQuaternion({0,0,1}, rotation),
	}
	return r3d.FrustumIntersectsOrientedBox(frustum, box)
}
