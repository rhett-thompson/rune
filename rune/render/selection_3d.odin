package render

import "core:math"
import "rune:assets"
import "rune:ecs"
import rl "vendor:raylib"

@(private)
Selection_Projection_3D :: struct {
	position, right, up, forward: [3]f32,
	viewport: [2]f32,
	near, far: f32,
	scale: f64,
	perspective: bool,
}

@(private)
Selection_Extents_3D :: struct {
	min, max: [2]f32,
	found: bool,
}

// Returns current rendered geometry bounds in canvas screen coordinates. The
// result is clipped to the viewport and uses composed entity TRS, cached static
// model bounds, and current CPU mesh vertices. No children, asset loads, GPU
// state, or renderer resources participate. These are bounding boxes rather than
// an alpha-, occlusion-, shader-, or animation-aware silhouette.
scene_selection_bounds_3d :: proc(world:^ecs.World, manager:^assets.Asset_Manager, entity:ecs.Entity, camera:rl.Camera3D, viewport:[2]f32, near,far:f32) -> (rl.Rectangle,bool) {
	if world==nil || !ecs.is_enabled(world,entity) {return {},false}
	projection,valid:=selection_projection_3d(camera,viewport,near,far)
	if !valid {return {},false}
	pose:=ecs.world_transform_3d(world,entity)
	if !pick_3d_vector_valid(pose.position) || !pick_3d_vector_valid(pose.rotation) || !pick_3d_vector_valid(pose.scale) || pose.scale[0]==0 || pose.scale[1]==0 || pose.scale[2]==0 {return {},false}
	model:=rl.MatrixTranslate(pose.position[0],pose.position[1],pose.position[2])*rl.QuaternionToMatrix(rl.QuaternionFromEuler(pose.rotation[0]*f32(math.PI/180),pose.rotation[1]*f32(math.PI/180),pose.rotation[2]*f32(math.PI/180)))*rl.MatrixScale(pose.scale[0],pose.scale[1],pose.scale[2])
	extents:Selection_Extents_3D
	if mesh,ok:=ecs.get_mesh_renderer(world,entity); ok {
		bounds:rl.BoundingBox; supported:=true
		switch mesh.primitive {
		case "cube": bounds={{-0.5,-0.5,-0.5},{0.5,0.5,0.5}}
		case "plane": bounds={{-0.5,0,-0.5},{0.5,0,0.5}}
		case "quad": bounds={{-0.5,-0.5,0},{0.5,0.5,0}}
		case "static":
			if state,available:=world.static_meshes[entity]; available && len(state.data.vertices)>0 {
				bounds={state.data.vertices[0].position,state.data.vertices[0].position}
				for vertex in state.data.vertices {
					if !pick_3d_vector_valid(vertex.position) {supported=false; break}
					for axis in 0..<3 {bounds.min[axis]=min(bounds.min[axis],vertex.position[axis]); bounds.max[axis]=max(bounds.max[axis],vertex.position[axis])}
				}
			} else {supported=false}
		case: supported=false
		}
		if supported {selection_include_box_3d(&extents,bounds,model,projection)}
	}
	if sphere,ok:=ecs.get_sphere_renderer(world,entity); ok && sphere.radius>0 && !math.is_nan(sphere.radius) && !math.is_inf(sphere.radius) {
		radius:=[3]f32{sphere.radius,sphere.radius,sphere.radius}
		selection_include_box_3d(&extents,{-radius,radius},model,projection)
	}
	if renderer,ok:=ecs.get_model_renderer(world,entity); ok && manager!=nil {
		if bounds,available:=assets.cached_model_bounds(manager,renderer.model); available {selection_include_box_3d(&extents,bounds,model,projection)}
	}
	if !extents.found {return {},false}
	left,right:=max(f32(0),extents.min[0]),min(viewport[0],extents.max[0])
	top,bottom:=max(f32(0),extents.min[1]),min(viewport[1],extents.max[1])
	if right<=left || bottom<=top {return {},false}
	return {left,top,right-left,bottom-top},true
}

@(private)
selection_projection_3d :: proc(camera:rl.Camera3D,viewport:[2]f32,near,far:f32) -> (Selection_Projection_3D,bool) {
	if !pick_3d_vector_valid(camera.position) || !pick_3d_vector_valid(camera.target) || !pick_3d_vector_valid(camera.up) {return {},false}
	for value in ([5]f32{viewport[0],viewport[1],camera.fovy,near,far}) {if math.is_nan(value) || math.is_inf(value) {return {},false}}
	if viewport[0]<=0 || viewport[1]<=0 || camera.fovy<=0 || near<0 || far<=near {return {},false}
	forward,valid:=pick_3d_unit(camera.target-camera.position); if !valid {return {},false}
	right:[3]f32
	right,valid=pick_3d_unit(rl.Vector3CrossProduct(forward,camera.up)); if !valid {return {},false}
	projection:=Selection_Projection_3D{position=camera.position,right=right,up=rl.Vector3CrossProduct(right,forward),forward=forward,viewport=viewport,near=near,far=far}
	switch camera.projection {
	case .PERSPECTIVE:
		if camera.fovy>=180 {return {},false}
		projection.perspective=true
		projection.scale=f64(viewport[1])/(2*math.tan(f64(camera.fovy)*(math.PI/360)))
		// A zero near plane is accepted by CPU callers; perspective projection
		// still needs a positive denominator at an intersecting camera plane.
		projection.near=max(near,f32(1.17549435e-38))
		if projection.far<=projection.near {return {},false}
	case .ORTHOGRAPHIC: projection.scale=f64(viewport[1])/f64(camera.fovy)
	case: return {},false
	}
	if projection.scale<=0 || math.is_nan(projection.scale) || math.is_inf(projection.scale) {return {},false}
	return projection,true
}

@(private)
selection_include_box_3d :: proc(extents:^Selection_Extents_3D,bounds:rl.BoundingBox,model:rl.Matrix,projection:Selection_Projection_3D) {
	if !pick_3d_bounds_valid(bounds) {return}
	points:[8][3]f32
	for index in 0..<8 {
		local:=[3]f32{bounds.min[0],bounds.min[1],bounds.min[2]}
		for axis in 0..<3 {if index & (1<<u32(axis))!=0 {local[axis]=bounds.max[axis]}}
		world:=rl.Vector3Transform(local,model)-projection.position
		points[index]={rl.Vector3DotProduct(world,projection.right),rl.Vector3DotProduct(world,projection.up),rl.Vector3DotProduct(world,projection.forward)}
		if !pick_3d_vector_valid(points[index]) {return}
	}
	// Near/far intersections can become the extrema when an edge crosses a
	// clipping plane. Projecting behind-camera corners would invert them.
	for index in 0..<8 {
		for axis in 0..<3 {
			other:=index | (1<<u32(axis))
			if other==index {continue}
			a,b,visible:=selection_clip_edge_3d(points[index],points[other],projection.near,projection.far)
			if !visible {continue}
			selection_include_point_3d(extents,a,projection)
			selection_include_point_3d(extents,b,projection)
		}
	}
}

@(private)
selection_clip_edge_3d :: proc(a,b:[3]f32,near,far:f32) -> ([3]f32,[3]f32,bool) {
	if a[2]<near && b[2]<near || a[2]>far && b[2]>far {return {},{},false}
	start,finish:=f64(0),f64(1)
	delta:=f64(b[2])-f64(a[2])
	if delta!=0 {
		first,last:=(f64(near)-f64(a[2]))/delta,(f64(far)-f64(a[2]))/delta
		start=max(start,min(first,last)); finish=min(finish,max(first,last))
		if start>finish {return {},{},false}
	}
	clipped_a,clipped_b:[3]f32
	for axis in 0..<3 {
		difference:=f64(b[axis])-f64(a[axis])
		clipped_a[axis]=f32(f64(a[axis])+difference*start)
		clipped_b[axis]=f32(f64(a[axis])+difference*finish)
	}
	// Keep rounding at a clipping plane from producing a zero denominator.
	clipped_a[2]=clamp(clipped_a[2],near,far); clipped_b[2]=clamp(clipped_b[2],near,far)
	return clipped_a,clipped_b,true
}

@(private)
selection_include_point_3d :: proc(extents:^Selection_Extents_3D,point:[3]f32,projection:Selection_Projection_3D) {
	scale:=projection.scale
	if projection.perspective {scale/=f64(point[2])}
	// f64 intermediates keep large finite world coordinates and tiny positive
	// near planes from overflowing before the final viewport clip.
	screen:=[2]f32{f32(clamp(f64(projection.viewport[0])/2+f64(point[0])*scale,0,f64(projection.viewport[0]))),f32(clamp(f64(projection.viewport[1])/2-f64(point[1])*scale,0,f64(projection.viewport[1])))}
	if !extents.found {extents.min=screen; extents.max=screen; extents.found=true; return}
	for axis in 0..<2 {extents.min[axis]=min(extents.min[axis],screen[axis]); extents.max[axis]=max(extents.max[axis],screen[axis])}
}
