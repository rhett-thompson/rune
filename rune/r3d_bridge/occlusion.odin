package r3d_bridge

import "core:math"
import "core:math/linalg"
import "core:slice"
import "rune:assets"
import "rune:ecs"
import r3d "r3d:r3d"
import rl "vendor:raylib"

Max_Projected_Occluders :: 128
Occlusion_Unproductive_Probe_Threshold :: 2
Occlusion_Max_Skipped_Frames :: 3
Occlusion_World_Face :: struct {
	points: [4][3]f32,
	normal: [3]f32,
	count: int,
}
Occlusion_Clip_Face :: struct {points:[4]rl.Vector4}

Projected_Occluder :: struct {
	points: [4][2]f32,
	count: int,
	low,high: [2]f32,
	far_depth,area,screen_area: f32,
	selection_order: int,
}
Occlusion_State :: struct {
	view_projection: rl.Matrix,
	camera_position: [3]f32,
	width,height: i32,
	material_revision: u64,
	dirty,prepared: bool,
	adaptive_enabled, useful, probe_pending, last_was_skipped: bool,
	unproductive_probes,skip_remaining: int,
	occluders: [Max_Projected_Occluders]Projected_Occluder,
	count: int,
}

record_occlusion_benefit :: proc(state:^Occlusion_State) {state.useful=true}

// Called after static meshes and lights have consumed this draw's fresh proof.
// Cached views do not count as another probe; light-only benefit also keeps the
// ordinary per-view work active while it is useful.
finish_occlusion_frame :: proc(ctx:^Context) {
	state:=&ctx.occlusion
	if !ctx.occlusion_adaptive_enabled {
		state.unproductive_probes=0;state.skip_remaining=0;state.probe_pending=false
		return
	}
	if state.useful {
		state.unproductive_probes=0;state.skip_remaining=0;state.probe_pending=false
		return
	}
	if !state.probe_pending {return}
	state.probe_pending=false
	state.unproductive_probes=min(Occlusion_Unproductive_Probe_Threshold,state.unproductive_probes+1)
	if state.unproductive_probes>=Occlusion_Unproductive_Probe_Threshold {state.skip_remaining=Occlusion_Max_Skipped_Frames}
}

// Only known opaque albedo can block other meshes. Unknown texture alpha,
// billboards, transparency, and custom surface shaders fail open.
occlusion_material :: proc(ctx:^Context,w:^ecs.World,manager:^assets.Asset_Manager,e:ecs.Entity) -> (opaque,eligible:bool,cull:r3d.CullMode) {
	opaque,eligible,cull=true,true,.BACK
	if renderer,found:=ecs.get_mesh_renderer(w,e); found && renderer.primitive=="static" {
		opaque=renderer.color.a==255
		if renderer.material!="" && manager!=nil {
			if data,loaded:=assets.material_data(manager,renderer.material); loaded {
				eligible=data.billboard=="disabled"
				opaque=eligible && data.transparency=="disabled" && data.blend=="mix" && data.base_color[3]==255 && data.texture=="" && data.alpha_cutoff<1
				if data.procedural.enabled {opaque=opaque && data.procedural.color_a[3]==255 && data.procedural.color_b[3]==255}
				cull=cull_mode_from_name(data.cull)
			}
			if cached,present:=ctx.r3d_materials[renderer.material]; present {
				m:=cached.material
				eligible=eligible && m.shader==nil && m.billboardMode==.DISABLED && m.depth.mode==.LESS && m.depth.rangeNear==0 && m.depth.rangeFar==1 && m.depth.offsetFactor==0 && m.depth.offsetUnits==0 && m.stencil.mode==.ALWAYS && m.stencil.opFail==.KEEP && m.stencil.opZFail==.KEEP
				opaque=opaque && eligible && m.transparencyMode==.DISABLED && m.blendMode==.MIX && m.albedo.color.a==255 && m.alphaCutoff<1
				cull=m.cullMode
			}
		}
	}
	// Authored material checks above may replace the fallback classification.
	// A fading surface can never prove that geometry or lights behind it are hidden.
	if state,found:=w.static_meshes[e]; found && state.opacity<1 {
		opaque=false
		if state.opacity<=0 {eligible=false}
	}
	return
}

project_occlusion_point :: proc(point:[3]f32,view_projection:rl.Matrix) -> ([3]f32,bool) {
	clip:=view_projection*rl.Vector4{point[0],point[1],point[2],1}
	return #force_inline project_occlusion_clip_point(clip)
}

project_occlusion_clip_point :: proc(clip:rl.Vector4) -> ([3]f32,bool) {
	// Near-plane crossings are retained, rather than approximated by a box.
	if !(clip[3]>0.00001) || !(clip[2]>-clip[3]+0.00001*clip[3]) || !(clip[2]<clip[3]) {return {},false}
	projected:=[3]f32{clip[0],clip[1],clip[2]}/clip[3]
	for value in projected {if math.is_nan(value) || math.is_inf(value) {return {},false}}
	return projected,true
}

release_occlusion_faces :: proc(cache:^Static_Mesh_Cache) {
	delete(cache.occlusion_faces); cache.occlusion_faces=nil
	delete(cache.occlusion_world_faces); cache.occlusion_world_faces=nil
	delete(cache.occlusion_clip_faces); cache.occlusion_clip_faces=nil
	cache.occlusion_faces_ready=false;cache.occlusion_world_ready=false;cache.occlusion_clip_ready=false
}

transform_occlusion_face :: proc(face:Occlusion_Face,transform:rl.Matrix) -> Occlusion_World_Face {
	world:=Occlusion_World_Face{count=face.count}
	for i in 0..<face.count {world.points[i]=rl.Vector3Transform(face.points[i],transform)}
	world.normal=linalg.cross(world.points[1]-world.points[0],world.points[2]-world.points[0])
	return world
}

// Extracted faces stay immutable until their mesh revision is replaced. Their
// world geometry changes only with the mesh transform, independently of camera.
prepare_occlusion_world_faces :: proc(cache:^Static_Mesh_Cache) -> bool {
	if cache.occlusion_world_ready && cache.occlusion_world_transform==cache.transform &&
	   len(cache.occlusion_world_faces)==len(cache.occlusion_faces) {return false}
	if len(cache.occlusion_world_faces)!=len(cache.occlusion_faces) {
		delete(cache.occlusion_world_faces)
		cache.occlusion_world_faces=make([]Occlusion_World_Face,len(cache.occlusion_faces))
	}
	for face,index in cache.occlusion_faces {cache.occlusion_world_faces[index]=transform_occlusion_face(face,cache.transform)}
	cache.occlusion_world_transform=cache.transform;cache.occlusion_world_ready=true
	cache.occlusion_clip_ready=false
	return true
}

// A translated camera changes only the last matrix column. Raylib matrices are
// row-major: Odin accumulates columns 0..3, with translation * 1 added last.
// Cache those first three terms and preserve the original final addition.
occlusion_projection_basis :: proc(view_projection:rl.Matrix) -> (basis:rl.Matrix,translation:rl.Vector4,valid:bool) {
	basis=view_projection
	for row in 0..<4 {
		for column in 0..<4 {
			value:=view_projection[row,column]
			if math.is_nan(value) || math.is_inf(value) {return {},{},false}
		}
		translation[row]=view_projection[row,3]
		basis[row,3]=0
	}
	return basis,translation,true
}

prepare_occlusion_clip_faces :: proc(cache:^Static_Mesh_Cache,basis:rl.Matrix) -> bool {
	if cache.occlusion_clip_ready && cache.occlusion_clip_basis==basis &&
	   len(cache.occlusion_clip_faces)==len(cache.occlusion_world_faces) {return false}
	if len(cache.occlusion_clip_faces)!=len(cache.occlusion_world_faces) {
		delete(cache.occlusion_clip_faces)
		cache.occlusion_clip_faces=make([]Occlusion_Clip_Face,len(cache.occlusion_world_faces))
	}
	for face,index in cache.occlusion_world_faces {
		for i in 0..<face.count {
			point:=face.points[i]
			cache.occlusion_clip_faces[index].points[i]=basis*rl.Vector4{point[0],point[1],point[2],1}
		}
	}
	cache.occlusion_clip_basis=basis;cache.occlusion_clip_ready=true
	return true
}

project_occlusion_face :: proc(face:Occlusion_Face,transform,view_projection:rl.Matrix,camera:[3]f32,cull:r3d.CullMode) -> (Projected_Occluder,bool) {
	return project_occlusion_world_face(transform_occlusion_face(face,transform),view_projection,camera,cull)
}

project_occlusion_world_face :: proc(face:Occlusion_World_Face,view_projection:rl.Matrix,camera:[3]f32,cull:r3d.CullMode) -> (Projected_Occluder,bool) {
	facing:=linalg.dot(face.normal,camera-face.points[0])
	if (cull==.BACK && !(facing>0)) || (cull==.FRONT && !(facing<0)) {return {},false}
	projected:=Projected_Occluder{count=face.count,far_depth=-1}
	for i in 0..<face.count {
		p,valid:=project_occlusion_point(face.points[i],view_projection)
		if !valid {return {},false}
		projected.points[i]={p[0],p[1]}
		projected.far_depth=max(projected.far_depth,p[2])
		if i==0 {projected.low=projected.points[i]; projected.high=projected.low}
		else {for axis in 0..<2 {projected.low[axis]=min(projected.low[axis],p[axis]); projected.high[axis]=max(projected.high[axis],p[axis])}}
	}
	for i in 0..<face.count {a,b:=projected.points[i],projected.points[(i+1)%face.count]; projected.area+=a[0]*b[1]-a[1]*b[0]}
	if !(abs(projected.area)>0.00001) || projected.high[0]< -1 || projected.low[0]>1 || projected.high[1]< -1 || projected.low[1]>1 {return {},false}
	return projected,true
}

project_occlusion_clip_face :: proc(face:Occlusion_World_Face,linear:Occlusion_Clip_Face,translation:rl.Vector4,camera:[3]f32,cull:r3d.CullMode) -> (Projected_Occluder,bool) {
	facing:=#force_inline linalg.dot(face.normal,camera-face.points[0])
	if (cull==.BACK && !(facing>0)) || (cull==.FRONT && !(facing<0)) {return {},false}
	projected:=Projected_Occluder{count=face.count,far_depth=-1}
	for i in 0..<face.count {
		// Preserve the row-major matrix product's fourth mul-add operand order.
		p,valid:=#force_inline project_occlusion_clip_point(translation+linear.points[i])
		if !valid {return {},false}
		projected.points[i]={p[0],p[1]}
		projected.far_depth=max(projected.far_depth,p[2])
		if i==0 {projected.low=projected.points[i];projected.high=projected.low}
		else {for axis in 0..<2 {projected.low[axis]=min(projected.low[axis],p[axis]);projected.high[axis]=max(projected.high[axis],p[axis])}}
	}
	for i in 0..<face.count {a,b:=projected.points[i],projected.points[(i+1)%face.count];projected.area+=a[0]*b[1]-a[1]*b[0]}
	if !(abs(projected.area)>0.00001) || projected.high[0]< -1 || projected.low[0]>1 || projected.high[1]< -1 || projected.low[1]>1 {return {},false}
	return projected,true
}

occluder_covers_rect :: proc(o:Projected_Occluder,low,high:[2]f32,near_depth:f32) -> bool {
	if !(o.far_depth+0.0001<near_depth) || low[0]<=o.low[0] || low[1]<=o.low[1] || high[0]>=o.high[0] || high[1]>=o.high[1] {return false}
	sign:f32=1 if o.area>0 else -1
	for i in 0..<o.count {
		a,b:=o.points[i],o.points[(i+1)%o.count]
		edge:=b-a
		// A linear edge test reaches its minimum at this rectangle corner.
		// Keep the original arithmetic and threshold; only remove the other
		// three, no-worse corner evaluations.
		corner:=[2]f32{low[0] if edge[1]*sign<=0 else high[0],low[1] if edge[0]*sign>=0 else high[1]}
		p:=corner-a
		if !((edge[0]*p[1]-edge[1]*p[0])*sign>0.00001) {return false}
	}
	return true
}

bounds_occluded :: proc(bounds:rl.BoundingBox,state:^Occlusion_State) -> bool {
	if state.count==0 {return false}
	low,high:[2]f32
	near_depth:f32=1
	for i in 0..<8 {
		corner:=rl.Vector3{bounds.max.x if i&1!=0 else bounds.min.x,bounds.max.y if i&2!=0 else bounds.min.y,bounds.max.z if i&4!=0 else bounds.min.z}
		p,valid:=project_occlusion_point(corner,state.view_projection)
		if !valid {return false}
		near_depth=min(near_depth,p[2])
		if i==0 {low={p[0],p[1]}; high=low}
		else {for axis in 0..<2 {low[axis]=min(low[axis],p[axis]); high[axis]=max(high[axis],p[axis])}}
	}
	if low[0]>1 || high[0]< -1 || low[1]>1 || high[1]< -1 {return false}
	// Expand by two render pixels; never erase a silhouette at a wall edge.
	margin:=[2]f32{4/f32(state.width),4/f32(state.height)}
	for axis in 0..<2 {low[axis]=max(low[axis],-1)-margin[axis]; high[axis]=min(high[axis],1)+margin[axis]}
	for i in 0..<state.count {
		if occluder_covers_rect(state.occluders[i],low,high,near_depth) {
			record_occlusion_benefit(state)
			return true
		}
	}
	return false
}

// Higher screen area wins; equal-area faces retain their first-seen order.
// The bounded heap keeps the worst retained candidate at its root.
occluder_precedes :: proc(a,b:Projected_Occluder) -> bool {
	return a.screen_area>b.screen_area || (a.screen_area==b.screen_area && a.selection_order<b.selection_order)
}

select_occluder :: proc(state:^Occlusion_State,candidate:Projected_Occluder) {
	if state.count<len(state.occluders) {
		index:=state.count;state.count+=1;state.occluders[index]=candidate
		for index>0 {
			parent:=(index-1)/2
			if !occluder_precedes(state.occluders[parent],state.occluders[index]) {break}
			state.occluders[parent],state.occluders[index]=state.occluders[index],state.occluders[parent]
			index=parent
		}
		return
	}
	if !occluder_precedes(candidate,state.occluders[0]) {return}
	state.occluders[0]=candidate
	index:=0
	for {
		child:=index*2+1
		if child>=state.count {break}
		if child+1<state.count && occluder_precedes(state.occluders[child],state.occluders[child+1]) {child+=1}
		if !occluder_precedes(state.occluders[index],state.occluders[child]) {break}
		state.occluders[index],state.occluders[child]=state.occluders[child],state.occluders[index]
		index=child
	}
}

occlusion_frustum_valid :: proc(frustum:^r3d.Frustum) -> bool {
	if frustum==nil {return false}
	for plane in frustum.planes {
		for value in plane {if math.is_nan(value) || math.is_inf(value) {return false}}
		length_squared:=plane[0]*plane[0]+plane[1]*plane[1]+plane[2]*plane[2]
		if !(length_squared>0) || math.is_inf(length_squared) {return false}
	}
	return true
}

// Bounds are already padded by static_world_bounds. Unusable bounds/frusta
// fail open and leave the existing per-face projection proof in charge.
occlusion_bounds_in_frustum :: proc(frustum:^r3d.Frustum,bounds:rl.BoundingBox) -> bool {
	if frustum==nil {return true}
	for axis in 0..<3 {
		if math.is_nan(bounds.min[axis]) || math.is_inf(bounds.min[axis]) ||
		   math.is_nan(bounds.max[axis]) || math.is_inf(bounds.max[axis]) || bounds.min[axis]>bounds.max[axis] {return true}
	}
	return r3d.FrustumIntersectsBoundingBox(frustum,bounds)
}

prepare_occlusion :: proc(ctx:^Context,w:^ecs.World,manager:^assets.Asset_Manager,camera:rl.Camera3D) {
	if !ctx.occlusion_enabled {return}
	width,height:i32; r3d.GetResolution(&width,&height)
	if width<=0 || height<=0 {return}
	render_camera:=r3d.CameraFromRL(camera)
	// Use the backend's exact current view, including its fitted viewport.
	view_projection:=r3d.GetMatrixViewProjection()
	frustum:=r3d.GetFrustum()
	prepare_occlusion_view(ctx,w,manager,camera.position,view_projection,&frustum,u32(render_camera.cullMask),width,height)
}

prepare_occlusion_view :: proc(ctx:^Context,w:^ecs.World,manager:^assets.Asset_Manager,camera:[3]f32,view_projection:rl.Matrix,frustum:^r3d.Frustum,cull_mask:u32,width,height:i32) {
	state:=&ctx.occlusion
	ctx.frame_stats.occlusion_probe_skipped=false
	state.probe_pending=false
	tested_frustum:=frustum
	if !occlusion_frustum_valid(frustum) {tested_frustum=nil}
	revision:u64; if manager!=nil {revision=manager.material_revision}
	basis,translation,basis_valid:=occlusion_projection_basis(view_projection)
	previous_basis:=state.view_projection
	for row in 0..<4 {previous_basis[row,3]=0}
	basis_stable:=state.prepared && basis_valid && previous_basis==basis
	policy_changed:=state.adaptive_enabled!=ctx.occlusion_adaptive_enabled
	state.adaptive_enabled=ctx.occlusion_adaptive_enabled
	if policy_changed || !ctx.occlusion_adaptive_enabled {state.unproductive_probes=0;state.skip_remaining=0}
	// Separate scene changes from camera-only motion. Scene/material/target or
	// policy changes must always get a fresh probe, even during a backoff.
	view_changed:=state.view_projection!=view_projection || state.camera_position!=camera
	force_probe:=state.dirty || !state.prepared || policy_changed || state.width!=width || state.height!=height || state.material_revision!=revision ||
		(!view_changed && state.last_was_skipped)
	state.dirty=force_probe || view_changed
	for e,&cache in ctx.static_meshes {
		// A completely offscreen mesh cannot supply an accepted projected face
		// or a visible occlusion target. Skip its material work and face loading.
		if !cache.enabled || !cache.valid || !occlusion_bounds_in_frustum(tested_frustum,cache.bounds) {
			if cache.occlusion_opaque || cache.occlusion_eligible {state.dirty=true;force_probe=true}
			cache.occlusion_opaque=false;cache.occlusion_eligible=false;cache.occluded=false
			continue
		}
		opaque,eligible,cull:=occlusion_material(ctx,w,manager,e)
		opaque=opaque && u32(cache.mesh.layerMask)&cull_mask!=0
		if cache.occlusion_opaque!=opaque || cache.occlusion_eligible!=eligible || cache.occlusion_cull!=cull {state.dirty=true;force_probe=true}
		cache.occlusion_opaque=opaque; cache.occlusion_eligible=eligible; cache.occlusion_cull=cull
		if opaque && !cache.occlusion_faces_ready {
			if data,present:=w.static_meshes[e]; present && data.revision==cache.revision {
				cache.occlusion_faces=extract_occlusion_faces(data.data)
				cache.occlusion_world_ready=false
				cache.occlusion_faces_ready=true;state.dirty=true;force_probe=true
			}
		}
		if opaque {
			world_rebuilt:=prepare_occlusion_world_faces(&cache)
			if world_rebuilt {state.dirty=true;force_probe=true}
			// Avoid rebuilding all clip terms during continuous camera rotation or
			// mesh movement. Repeated bases and stationary geometry amortize it.
			if basis_stable && !world_rebuilt {prepare_occlusion_clip_faces(&cache,basis)}
		}
	}
	if !state.dirty {ctx.frame_stats.occlusion_cache_reused=true; return}
	state.view_projection=view_projection; state.camera_position=camera
	state.width=width; state.height=height; state.material_revision=revision; state.count=0
	if ctx.occlusion_adaptive_enabled && !force_probe &&
	   state.unproductive_probes>=Occlusion_Unproductive_Probe_Threshold && state.skip_remaining>0 {
		// An absent proof cannot hide anything. Render this changed view fully,
		// rather than retaining cached mesh or local-light occlusion decisions.
		for _,&cache in ctx.static_meshes {cache.occluded=false}
		state.skip_remaining-=1;state.useful=false
		state.last_was_skipped=true
		state.dirty=false;state.prepared=true
		ctx.frame_stats.occlusion_probe_skipped=true
		return
	}
	state.useful=false
	state.last_was_skipped=false
	selection_order:=0
	for _,cache in ctx.static_meshes {
		if !cache.enabled || !cache.valid || !cache.occlusion_opaque {continue}
		for face,index in cache.occlusion_world_faces {
			projected:Projected_Occluder;valid:bool
			if basis_valid && cache.occlusion_clip_ready && cache.occlusion_clip_basis==basis {
				projected,valid=#force_inline project_occlusion_clip_face(face,cache.occlusion_clip_faces[index],translation,camera,cache.occlusion_cull)
			} else {
				projected,valid=project_occlusion_world_face(face,view_projection,camera,cache.occlusion_cull)
			}
			if !valid {continue}
			// Prioritize large on-screen blockers; a budget can only miss culls.
			score:=max(0,min(projected.high[0],1)-max(projected.low[0],-1))*max(0,min(projected.high[1],1)-max(projected.low[1],-1))
			projected.screen_area=score
			projected.selection_order=selection_order;selection_order+=1
			select_occluder(state,projected)
		}
	}
	slice.sort_by(state.occluders[:state.count],occluder_precedes)
	for _,&cache in ctx.static_meshes {
		cache.occluded=false
		if cache.enabled && cache.valid && cache.occlusion_eligible {
			ctx.frame_stats.occlusion_tests+=1
			cache.occluded=bounds_occluded(cache.bounds,state)
		}
	}
	state.dirty=false;state.prepared=true;state.probe_pending=true
}
