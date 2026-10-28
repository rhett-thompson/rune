package r3d_bridge

import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "core:testing"
import "rune:ecs"
import r3d "r3d:r3d"
import rl "vendor:raylib"

// The previous uncached projection is the oracle for the new world-pose cache.
// Keep the world transform and facing calculation here independent of its helpers.
occlusion_test_reference_projection :: proc(face:Occlusion_Face,transform,view_projection:rl.Matrix,camera:[3]f32,cull:r3d.CullMode) -> (Projected_Occluder,bool) {
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
		if i==0 {projected.low=projected.points[i];projected.high=projected.low}
		else {for axis in 0..<2 {projected.low[axis]=min(projected.low[axis],p[axis]);projected.high[axis]=max(projected.high[axis],p[axis])}}
	}
	for i in 0..<face.count {a,b:=projected.points[i],projected.points[(i+1)%face.count];projected.area+=a[0]*b[1]-a[1]*b[0]}
	if !(abs(projected.area)>0.00001) || projected.high[0]< -1 || projected.low[0]>1 || projected.high[1]< -1 || projected.low[1]>1 {return {},false}
	return projected,true
}

@(test)
occlusion_cached_world_faces_match_uncached_projection_through_camera_and_pose_changes :: proc(t:^testing.T) {
	face:=Occlusion_Face{count=4,points={{-1.2,-1.2,-3},{1.2,-1.2,-3},{1.2,1.2,-3},{-1.2,1.2,-3}}}
	projection:=rl.MatrixPerspective(60*math.PI/180,1.5,0.1,100)
	for transform in ([4]rl.Matrix{
		rl.Matrix(1),
		rl.MatrixTranslate(0.3,-0.2,-2)*rl.MatrixRotateXYZ({0.1,0.3,-0.2})*rl.MatrixScale(1.7,0.6,1.1),
		rl.MatrixTranslate(-0.5,0.2,-1)*rl.MatrixRotateXYZ({0,3,0})*rl.MatrixScale(0.8,1.3,2),
		rl.MatrixTranslate(0,0,2.95),
	}) {
		world:=transform_occlusion_face(face,transform)
		for camera in ([4][3]f32{{},{0.1,0.2,0.3},{-0.5,0,-0.1},{0,0,-8}}) {
			for direction in ([2][3]f32{{0,0,-1},{0.12,0.04,-1}}) {
				view_projection:=projection*rl.MatrixLookAt(camera,camera+direction,{0,1,0})
				for cull in ([3]r3d.CullMode{.NONE,.BACK,.FRONT}) {
					expected,expected_valid:=occlusion_test_reference_projection(face,transform,view_projection,camera,cull)
					actual,actual_valid:=project_occlusion_world_face(world,view_projection,camera,cull)
					testing.expect(t,actual_valid==expected_valid && actual==expected,"world-pose caching keeps facing, near-plane rejection and exact projected bounds")
				}
			}
		}
	}
	bad:=face;bad.points[0][0]=math.nan_f32()
	_,valid:=project_occlusion_world_face(transform_occlusion_face(bad,rl.Matrix(1)),projection,{},.NONE)
	testing.expect(t,!valid,"nonfinite projected geometry still fails open")
}

@(test)
occlusion_world_pose_cache_reuses_camera_moves_and_refreshes_moved_blockers :: proc(t:^testing.T) {
	w:=ecs.init();defer ecs.destroy(&w)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
	ctx:=new(Context);ctx.static_meshes=make(map[ecs.Entity]Static_Mesh_Cache)
	defer {for _,&cache in ctx.static_meshes {release_occlusion_faces(&cache)};delete(ctx.static_meshes);free(ctx)}
	front:=occlusion_test_cached_quad(ctx,&w,&r,-3,1.2)
	target:=occlusion_test_cached_quad(ctx,&w,&r,-7,0.25)
	projection:=rl.MatrixPerspective(60*math.PI/180,1,0.1,100)
	frustum:=r3d.ComputeFrustum(projection)
	prepare_occlusion_view(ctx,&w,nil,{},projection,&frustum,1,320,320)
	testing.expect(t,ctx.static_meshes[target].occluded,"an opaque wall occludes its target before moving")
	old:=ctx.static_meshes[front]
	world_faces:=make([]Occlusion_World_Face,len(old.occlusion_world_faces));defer delete(world_faces)
	copy(world_faces,old.occlusion_world_faces)
	for camera in ([3][3]f32{{0.1,0,0},{-0.1,0.05,0},{0,0,0}}) {
		view:=projection*rl.MatrixLookAt(camera,camera+[3]f32{0.03,0,-1},{0,1,0})
		current_frustum:=r3d.ComputeFrustum(view)
		prepare_occlusion_view(ctx,&w,nil,camera,view,&current_frustum,1,320,320)
		current:=ctx.static_meshes[front]
		testing.expect(t,raw_data(current.occlusion_world_faces)==raw_data(old.occlusion_world_faces) && slice.equal(current.occlusion_world_faces,world_faces),"camera translation and rotation reuse the same world-face storage and values")
	}
	// Keep the moved blocker visible while shifting its real face off the target.
	cache:=ctx.static_meshes[front]
	cache.transform=rl.MatrixTranslate(3,0,0)*rl.MatrixRotateXYZ({0,0.15,0})*rl.MatrixScale(1.2,0.8,1.1)
	cache.bounds=static_world_bounds({{-1.2,-1.2,-3},{1.2,1.2,-3}},cache.transform)
	ctx.static_meshes[front]=cache
	prepare_occlusion_view(ctx,&w,nil,{},projection,&frustum,1,320,320)
	current:=ctx.static_meshes[front]
	testing.expect(t,current.occlusion_world_transform==cache.transform &&
		slice.equal(current.occlusion_world_faces,world_faces)==false,"a changed nonuniform world pose refreshes cached geometry")
	testing.expect(t,!ctx.static_meshes[target].occluded,"moving a wall cannot retain its old hidden-target proof")
	for local,index in current.occlusion_faces {
		testing.expect(t,current.occlusion_world_faces[index]==transform_occlusion_face(local,cache.transform),"refreshed faces match the real transformed surface")
	}
}

occlusion_test_reference_bounds :: proc(bounds:rl.BoundingBox,state:^Occlusion_State) -> bool {
	if state.count==0 {return false}
	low,high:[2]f32
	near_depth:f32=1
	for i in 0..<8 {
		corner:=rl.Vector3{bounds.max.x if i&1!=0 else bounds.min.x,bounds.max.y if i&2!=0 else bounds.min.y,bounds.max.z if i&4!=0 else bounds.min.z}
		p,valid:=project_occlusion_point(corner,state.view_projection)
		if !valid {return false}
		near_depth=min(near_depth,p[2])
		if i==0 {low={p[0],p[1]};high=low}
		else {for axis in 0..<2 {low[axis]=min(low[axis],p[axis]);high[axis]=max(high[axis],p[axis])}}
	}
	if low[0]>1 || high[0]< -1 || low[1]>1 || high[1]< -1 {return false}
	margin:=[2]f32{4/f32(state.width),4/f32(state.height)}
	for axis in 0..<2 {low[axis]=max(low[axis],-1)-margin[axis];high[axis]=min(high[axis],1)+margin[axis]}
	for i in 0..<state.count {if occlusion_test_four_corner_coverage(state.occluders[i],low,high,near_depth) {return true}}
	return false
}

@(test)
occlusion_translated_views_match_full_projection_without_stale_visibility :: proc(t:^testing.T) {
	w:=ecs.init();defer ecs.destroy(&w)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
	ctx:=new(Context);ctx.static_meshes=make(map[ecs.Entity]Static_Mesh_Cache)
	defer {for _,&cache in ctx.static_meshes {release_occlusion_faces(&cache)};delete(ctx.static_meshes);free(ctx)}
	occlusion_test_cached_quad(ctx,&w,&r,-3.137,1.2)
	occlusion_test_cached_quad(ctx,&w,&r,-7.213,0.25)
	projection:=rl.MatrixPerspective(67*math.PI/180,1.3,0.1,100)
	for scenario in 0..<4 {
		basis:=projection
		if scenario==1 {basis=projection*rl.MatrixRotateY(0.17)*rl.MatrixRotateX(-0.08)}
		else if scenario==2 {basis=rl.MatrixPerspective(49*math.PI/180,1.9,0.2,80)*rl.MatrixRotateY(-0.13)}
		else if scenario==3 {basis=projection;basis[0,0]=math.nan_f32()}
		for i in 0..<11 {
			camera:=[3]f32{f32(i-5)*0.0317,f32((i*3)%7-3)*0.0173,f32(i)*0.0619}
			if i==10 {camera[2]=-3.1}
			view:=basis*rl.MatrixTranslate(-camera[0],-camera[1],-camera[2])
			prepare_occlusion_view(ctx,&w,nil,camera,view,nil,1,320,240)
			state:=Occlusion_State{view_projection=view,width=320,height=240}
			for _,cache in ctx.static_meshes {
				for face in cache.occlusion_faces {
					projected,valid:=occlusion_test_reference_projection(face,cache.transform,view,camera,cache.occlusion_cull)
					if valid {state.occluders[state.count]=projected;state.count+=1}
				}
			}
			testing.expect(t,ctx.occlusion.count==state.count,"camera translation and basis changes retain the full-product face selection")
			for expected in state.occluders[:state.count] {
				found:=false
			for cached in ctx.occlusion.occluders[:ctx.occlusion.count] {
				actual:=cached
					actual.screen_area=0;actual.selection_order=0
					if actual==expected {found=true;break}
				}
				testing.expect(t,found,"cached clip coordinates match the uncached projected face exactly")
			}
			for _,cache in ctx.static_meshes {testing.expect(t,cache.occluded==occlusion_test_reference_bounds(cache.bounds,&state),"translated views never retain an obsolete hidden-target result")}
		}
	}
}

@(test)
occlusion_clip_basis_cache_reuses_only_translation_and_matches_full_products :: proc(t:^testing.T) {
	face:=Occlusion_Face{count=4,points={{-1.173,-1.219,-3.137},{1.231,-1.113,-3.137},{1.197,1.271,-3.137},{-1.157,1.183,-3.137}}}
	cache:=Static_Mesh_Cache{occlusion_faces=make([]Occlusion_Face,1),occlusion_faces_ready=true}
	cache.occlusion_faces[0]=face
	defer release_occlusion_faces(&cache)
	for offset in ([3][3]f32{{},{987.654,123.456,-4321.234},{-0.0003125,0.00007125,-0.0008875}}) {
		transform:=rl.MatrixTranslate(offset[0],offset[1],offset[2])*
			rl.MatrixRotateXYZ({0.137,-0.234,0.071})*rl.MatrixScale(1.7,0.6,0.9)
		cache.transform=transform
		testing.expect(t,prepare_occlusion_world_faces(&cache) && !cache.occlusion_clip_ready,"changing a world pose invalidates its cached clip basis")
		for scenario in 0..<4 {
			projection:=rl.MatrixPerspective(67*math.PI/180,1.3,0.1,100)
			basis_view:=projection*rl.MatrixRotateY(0.137)*rl.MatrixRotateX(-0.083)
			if scenario==1 {basis_view=rl.MatrixPerspective(49*math.PI/180,1.9,0.2,80)*rl.MatrixRotateY(-0.13)}
			else if scenario==2 {basis_view=projection*rl.MatrixRotateY(f32(math.PI))}
			else if scenario==3 {basis_view[2,1]=math.nan_f32()}
			for i in 0..<9 {
				camera:=offset+[3]f32{f32(i-4)*0.0317,f32((i*3)%7-3)*0.0173,0.1237+f32(i)*0.0619}
				if i==8 {camera[2]=offset[2]-2.95}
				view:=basis_view*rl.MatrixTranslate(-camera[0],-camera[1],-camera[2])
				basis,translation,valid:=occlusion_projection_basis(view)
				if !valid {
					_,expected_valid:=occlusion_test_reference_projection(face,transform,view,camera,.NONE)
					_,actual_valid:=project_occlusion_world_face(cache.occlusion_world_faces[0],view,camera,.NONE)
					testing.expect(t,!expected_valid && !actual_valid,"nonfinite bases keep the full-projection fail-open fallback")
					continue
				}
				was_current:=cache.occlusion_clip_ready && cache.occlusion_clip_basis==basis
				previous:Occlusion_Clip_Face
				if was_current {previous=cache.occlusion_clip_faces[0]}
				rebuilt:=prepare_occlusion_clip_faces(&cache,basis)
				testing.expect(t,rebuilt==!was_current,"rotation and projection changes rebuild the basis, translation alone reuses it")
				if was_current {testing.expect(t,cache.occlusion_clip_faces[0]==previous,"translation reuses exact linear clip coordinates")}
				for cull in ([3]r3d.CullMode{.NONE,.BACK,.FRONT}) {
					expected,expected_valid:=occlusion_test_reference_projection(face,transform,view,camera,cull)
					actual,actual_valid:=project_occlusion_clip_face(cache.occlusion_world_faces[0],cache.occlusion_clip_faces[0],translation,camera,cull)
					testing.expect(t,actual_valid==expected_valid && actual==expected,"cached linear clip terms preserve the full product at irregular coordinates, near planes and reversed views")
				}
			}
		}
	}
}

occlusion_test_four_corner_coverage :: proc(o:Projected_Occluder,low,high:[2]f32,near_depth:f32) -> bool {
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

@(test)
occlusion_rectangle_support_corner_matches_all_four_corners :: proc(t:^testing.T) {
	projection:=rl.MatrixPerspective(60*math.PI/180,1,0.1,100)
	face:=Occlusion_Face{count=4,points={{-1.2,-1.2,-3},{1.2,-1.2,-3},{1.2,1.2,-3},{-1.2,1.2,-3}}}
	for turn in 0..<12 {
		transform:=rl.MatrixRotateZ(f32(turn)*0.137)
		for reversed in ([2]bool{false,true}) {
			candidate:=face
			if reversed {candidate.points[1],candidate.points[3]=candidate.points[3],candidate.points[1]}
			o,valid:=occlusion_test_reference_projection(candidate,transform,projection,{},.NONE)
			assert(valid)
			for i in 0..<257 {
				x:=f32((i*71)%257)/128-1
				y:=f32((i*113)%257)/128-1
				half:=[2]f32{f32(i%13+1)*0.025,f32(i%7+1)*0.025}
				low,high:=[2]f32{x,y}-half,[2]f32{x,y}+half
				for depth in ([3]f32{o.far_depth,o.far_depth+0.0001,o.far_depth+0.001}) {
					testing.expect(t,occluder_covers_rect(o,low,high,depth)==occlusion_test_four_corner_coverage(o,low,high,depth),"the support corner preserves every edge and depth decision of the four-corner proof")
				}
			}
			for epsilon in ([5]f32{0,0.000001,0.00001,0.0001,0.001}) {
				low,high:=o.low+[2]f32{epsilon,epsilon},o.high-[2]f32{epsilon,epsilon}
				testing.expect(t,occluder_covers_rect(o,low,high,1)==occlusion_test_four_corner_coverage(o,low,high,1),"silhouette-adjacent rectangles retain the conservative margin")
			}
		}
	}
}

@(test)
occlusion_world_face_storage_is_counted_and_released :: proc(t:^testing.T) {
	tracker:mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker,context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	context.allocator=mem.tracking_allocator(&tracker)
	ctx:=Context{static_meshes=make(map[ecs.Entity]Static_Mesh_Cache)}
	cache:=Static_Mesh_Cache{occlusion_faces=make([]Occlusion_Face,1),occlusion_faces_ready=true,transform=rl.Matrix(1)}
	cache.occlusion_faces[0]={count=3,points={{-1,-1,-3},{1,-1,-3},{0,1,-3},{}}}
	testing.expect(t,prepare_occlusion_world_faces(&cache))
	testing.expect(t,!prepare_occlusion_world_faces(&cache),"an unchanged pose requires no new world-face work")
	basis,_,valid:=occlusion_projection_basis(rl.MatrixPerspective(60*math.PI/180,1,0.1,100))
	assert(valid)
	testing.expect(t,prepare_occlusion_clip_faces(&cache,basis))
	ctx.static_meshes[ecs.Entity(1)]=cache
	testing.expect(t,memory_stats(&ctx).occlusion_face_bytes==size_of(Occlusion_Face)+size_of(Occlusion_World_Face)+size_of(Occlusion_Clip_Face),"memory estimates include local, world and cached clip faces")
	for _,&entry in ctx.static_meshes {release_occlusion_faces(&entry)}
	testing.expect(t,memory_stats(&ctx).occlusion_face_bytes==0)
	delete(ctx.static_meshes)
	testing.expect(t,tracker.current_memory_allocated==0,"world-face teardown releases every owned allocation")
}
