package r3d_bridge

import "core:math"
import "core:math/linalg"
import "rune:assets"
import "rune:ecs"
import r3d "r3d:r3d"
import rl "vendor:raylib"

Max_Projected_Occluders :: 128
Projected_Occluder :: struct {
	points: [4][2]f32,
	count: int,
	low,high: [2]f32,
	far_depth,area,screen_area: f32,
}
Occlusion_State :: struct {
	view_projection: rl.Matrix,
	camera_position: [3]f32,
	width,height: i32,
	material_revision: u64,
	dirty,prepared: bool,
	occluders: [Max_Projected_Occluders]Projected_Occluder,
	count: int,
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
	return
}

project_occlusion_point :: proc(point:[3]f32,view_projection:rl.Matrix) -> ([3]f32,bool) {
	clip:=view_projection*rl.Vector4{point[0],point[1],point[2],1}
	// Near-plane crossings are retained, rather than approximated by a box.
	if !(clip[3]>0.00001) || !(clip[2]>-clip[3]+0.00001*clip[3]) || !(clip[2]<clip[3]) {return {},false}
	projected:=[3]f32{clip[0],clip[1],clip[2]}/clip[3]
	for value in projected {if math.is_nan(value) || math.is_inf(value) {return {},false}}
	return projected,true
}

project_occlusion_face :: proc(face:Occlusion_Face,transform,view_projection:rl.Matrix,camera:[3]f32,cull:r3d.CullMode) -> (Projected_Occluder,bool) {
	world:[4]rl.Vector3
	for i in 0..<face.count {world[i]=rl.Vector3Transform(face.points[i],transform)}
	normal:=linalg.cross(world[1]-world[0],world[2]-world[0])
	facing:=linalg.dot(normal,camera-world[0])
	if (cull==.BACK && !(facing>0)) || (cull==.FRONT && !(facing<0)) {return {},false}
	projected:=Projected_Occluder{count=face.count,far_depth=-1}
	for i in 0..<face.count {
		p,valid:=project_occlusion_point(world[i],view_projection)
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

occluder_covers_rect :: proc(o:Projected_Occluder,low,high:[2]f32,near_depth:f32) -> bool {
	if !(o.far_depth+0.0001<near_depth) || low[0]<=o.low[0] || low[1]<=o.low[1] || high[0]>=o.high[0] || high[1]>=o.high[1] {return false}
	sign:f32=1 if o.area>0 else -1
	for i in 0..<o.count {
		a,b:=o.points[i],o.points[(i+1)%o.count]
		edge:=b-a
		for corner in ([4][2]f32{low,{high[0],low[1]},high,{low[0],high[1]}}) {
			p:=corner-a
			if !((edge[0]*p[1]-edge[1]*p[0])*sign>0.00001) {return false}
		}
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
	for i in 0..<state.count {if occluder_covers_rect(state.occluders[i],low,high,near_depth) {return true}}
	return false
}

prepare_occlusion :: proc(ctx:^Context,w:^ecs.World,manager:^assets.Asset_Manager,camera:rl.Camera3D) {
	if !ctx.occlusion_enabled {return}
	state:=&ctx.occlusion
	width,height:i32; r3d.GetResolution(&width,&height)
	if width<=0 || height<=0 {return}
	render_camera:=r3d.CameraFromRL(camera)
	// Use the backend's exact current view, including its fitted viewport.
	view_projection:=r3d.GetMatrixViewProjection()
	revision:u64; if manager!=nil {revision=manager.material_revision}
	state.dirty=state.dirty || !state.prepared || state.view_projection!=view_projection || state.camera_position!=camera.position || state.width!=width || state.height!=height || state.material_revision!=revision
	for e,&cache in ctx.static_meshes {
		opaque,eligible,cull:=occlusion_material(ctx,w,manager,e)
		opaque=opaque && u32(cache.mesh.layerMask)&u32(render_camera.cullMask)!=0
		if cache.occlusion_opaque!=opaque || cache.occlusion_eligible!=eligible || cache.occlusion_cull!=cull {state.dirty=true}
		cache.occlusion_opaque=opaque; cache.occlusion_eligible=eligible; cache.occlusion_cull=cull
		if !cache.occlusion_faces_ready {
			if data,present:=w.static_meshes[e]; present && data.revision==cache.revision {
				cache.occlusion_faces=extract_occlusion_faces(data.data)
				cache.occlusion_faces_ready=true; state.dirty=true
			}
		}
	}
	if !state.dirty {ctx.frame_stats.occlusion_cache_reused=true; return}
	state.view_projection=view_projection; state.camera_position=camera.position
	state.width=width; state.height=height; state.material_revision=revision; state.count=0
	for _,cache in ctx.static_meshes {
		if !cache.enabled || !cache.valid || !cache.occlusion_opaque {continue}
		for face in cache.occlusion_faces {
			projected,valid:=project_occlusion_face(face,cache.transform,view_projection,camera.position,cache.occlusion_cull)
			if !valid {continue}
			// Prioritize large on-screen blockers; a budget can only miss culls.
			score:=max(0,min(projected.high[0],1)-max(projected.low[0],-1))*max(0,min(projected.high[1],1)-max(projected.low[1],-1))
			projected.screen_area=score
			if state.count==len(state.occluders) && score<=state.occluders[state.count-1].screen_area {continue}
			position:=state.count
			for j in 0..<state.count {if score>state.occluders[j].screen_area {position=j; break}}
			if position==len(state.occluders) {continue}
			state.count=min(state.count+1,len(state.occluders))
			for j:=state.count-1; j>position; j-=1 {state.occluders[j]=state.occluders[j-1]}
			state.occluders[position]=projected
		}
	}
	for _,&cache in ctx.static_meshes {
		cache.occluded=false
		if cache.enabled && cache.valid && cache.occlusion_eligible {
			ctx.frame_stats.occlusion_tests+=1
			cache.occluded=bounds_occluded(cache.bounds,state)
		}
	}
	state.dirty=false; state.prepared=true
}
