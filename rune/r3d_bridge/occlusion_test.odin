package r3d_bridge

import "core:testing"
import "core:math"
import "core:slice"
import "rune:ecs"
import "rune:geometry"
import r3d "r3d:r3d"
import rl "vendor:raylib"

@(test)
occlusion_uses_only_real_opaque_convex_faces :: proc(t:^testing.T) {
	mesh:geometry.Mesh; defer geometry.destroy_mesh(&mesh)
	for p in ([4][3]f32{{-2,-2,-3},{2,-2,-3},{2,2,-3},{-2,2,-3}}) {append(&mesh.vertices,geometry.Vertex{position=p,color={255,255,255,255}})}
	append(&mesh.indices,0,1,2,0,2,3)
	faces:=extract_occlusion_faces(mesh); defer delete(faces)
	testing.expect(t,len(faces)==1 && faces[0].count==4,"triangle diagonal must not create a visibility gap")
	mesh.vertices[3].position[2]=-2.999
	nonplanar:=extract_occlusion_faces(mesh); defer delete(nonplanar)
	testing.expect(t,len(nonplanar)==2 && nonplanar[0].count==3 && nonplanar[1].count==3,"nearly coplanar triangles cannot fill space between their surfaces")
	mesh.vertices[3].position={0,0,-3}
	concave:=extract_occlusion_faces(mesh); defer delete(concave)
	for face in concave {testing.expect(t,face.count==3,"concave geometry cannot fill a hole")}
	for &v in mesh.vertices {v.color[3]=128}
	transparent:=extract_occlusion_faces(mesh); defer delete(transparent)
	testing.expect(t,len(transparent)==0,"vertex alpha must not hide other geometry")
}

@(test)
occlusion_retains_near_edges_gaps_and_wrong_depth :: proc(t:^testing.T) {
	projection:=rl.MatrixPerspective(60*math.PI/180,1,0.1,100)
	identity:=rl.Matrix(1)
	face:=Occlusion_Face{count=4,points={{-1.2,-1.2,-3},{1.2,-1.2,-3},{1.2,1.2,-3},{-1.2,1.2,-3}}}
	projected,valid:=project_occlusion_face(face,identity,projection,{},.BACK)
	testing.expect(t,valid)
	state:=Occlusion_State{view_projection=projection,width=320,height=320,count=1}
	state.occluders[0]=projected
	testing.expect(t,bounds_occluded({{-0.5,-0.5,-7},{0.5,0.5,-6}},&state),"small bounds wholly behind an opaque face are hidden")
	testing.expect(t,!bounds_occluded({{-0.5,-0.5,-2},{0.5,0.5,-1}},&state),"foreground geometry is visible")
	testing.expect(t,!bounds_occluded({{-0.5,-0.5,-4},{0.5,0.5,-3}},&state),"coplanar geometry and the occluder itself remain visible")
	testing.expect(t,!bounds_occluded({{-0.5,-0.5,-1},{0.5,0.5,0.1}},&state),"near-plane intersections fail open")
	testing.expect(t,!bounds_occluded({{2.2,-0.5,-7},{2.7,0.5,-6}},&state),"partly exposed silhouettes cannot be culled")
	_,valid=project_occlusion_face(face,identity,projection,{},.FRONT)
	testing.expect(t,!valid,"culled sides cannot occlude")
	near_face:=face; for &p in near_face.points {p[2]=-0.05}
	_,valid=project_occlusion_face(near_face,identity,projection,{},.BACK)
	testing.expect(t,!valid,"near-clipped occluders are ignored")
	// A wall split around a doorway must retain a mesh viewed through it.
	state.count=2
	left:=face; left.points[1][0]=-0.75; left.points[2][0]=-0.75
	right:=face; right.points[0][0]=0.75; right.points[3][0]=0.75
	state.occluders[0],_=project_occlusion_face(left,identity,projection,{},.BACK)
	state.occluders[1],_=project_occlusion_face(right,identity,projection,{},.BACK)
	testing.expect(t,!bounds_occluded({{-0.5,-0.5,-7},{0.5,0.5,-6}},&state),"a doorway remains open in the visibility proof")
}

@(test)
occlusion_bounded_selection_matches_stable_full_sort_including_equal_area_cutoffs :: proc(t:^testing.T) {
	for scenario in 0..<4 {for count in ([7]int{0,1,127,128,129,513,4096}) {
		candidates:=make([]Projected_Occluder,count);defer delete(candidates)
		state:Occlusion_State
		for &candidate,index in candidates {
			score:=f32((index*73)%113)/32
			if scenario==1 {score=f32(index)/1024}
			else if scenario==2 {score=f32(count-index)/1024}
			else if scenario==3 {score=1}
			candidate.screen_area=score;candidate.selection_order=index
			candidate.points[0]={f32(index),f32(scenario)}
			select_occluder(&state,candidate)
		}
		slice.sort_by(state.occluders[:state.count],occluder_precedes)
		// An unbounded stable reference expresses the original priority without
		// sharing the bounded heap's insertion/replacement implementation.
		slice.stable_sort_by(candidates,proc(a,b:Projected_Occluder)->bool {return a.screen_area>b.screen_area})
		expected:=min(count,Max_Projected_Occluders)
		testing.expect(t,state.count==expected && slice.equal(state.occluders[:state.count],candidates[:expected]),"bounded selection preserves exactly the highest-area faces and first-seen ties")
	}}
}

occlusion_test_cached_quad :: proc(ctx:^Context,w:^ecs.World,r:^ecs.Component_Registry,z,half:f32,reverse:bool=false) -> ecs.Entity {
	mesh:geometry.Mesh;defer geometry.destroy_mesh(&mesh)
	for point in ([4][3]f32{{-half,-half,z},{half,-half,z},{half,half,z},{-half,half,z}}) {
		append(&mesh.vertices,geometry.Vertex{position=point,normal={0,0,(-1 if reverse else 1)},color={255,255,255,255}})
	}
	if reverse {append(&mesh.indices,0,2,1,0,3,2)}
	else {append(&mesh.indices,0,1,2,0,2,3)}
	entity:=ecs.create_entity(w)
	assert(ecs.add(w,r,entity,ecs.default_transform()) && ecs.set_static_mesh(w,entity,mesh,collidable=false))
	identity:=rl.Matrix(1)
	ctx.static_meshes[entity]={mesh=r3d.Mesh{layerMask=.LAYER_01},revision=w.static_meshes[entity].revision,
		transform=identity,bounds=static_world_bounds({{-half,-half,z},{half,half,z}},identity),enabled=true,valid=true}
	return entity
}

@(test)
occlusion_skips_offscreen_face_preparation_and_rechecks_visibility_on_rotation :: proc(t:^testing.T) {
	w:=ecs.init();defer ecs.destroy(&w)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
	ctx:=new(Context);ctx.static_meshes=make(map[ecs.Entity]Static_Mesh_Cache)
	defer {for _,cache in ctx.static_meshes {delete(cache.occlusion_faces)};delete(ctx.static_meshes);free(ctx)}
	front:=occlusion_test_cached_quad(ctx,&w,&r,-3,1.2)
	target:=occlusion_test_cached_quad(ctx,&w,&r,-7,0.25)
	back:=occlusion_test_cached_quad(ctx,&w,&r,3,1.2,true)
	projection:=rl.MatrixPerspective(60*math.PI/180,1,0.1,100)
	frustum:=r3d.ComputeFrustum(projection)
	prepare_occlusion_view(ctx,&w,nil,{},projection,&frustum,1,320,320)
	testing.expect(t,ctx.occlusion.count==2 && ctx.static_meshes[front].occlusion_faces_ready && ctx.static_meshes[target].occluded,"visible opaque faces retain the same conservative hidden-target proof")
	testing.expect(t,!ctx.static_meshes[back].occlusion_faces_ready && !ctx.static_meshes[back].occlusion_eligible,"an offscreen cache incurs no face extraction or target test")
	ctx.frame_stats={}
	prepare_occlusion_view(ctx,&w,nil,{},projection,&frustum,1,320,320)
	testing.expect(t,ctx.frame_stats.occlusion_cache_reused,"an unchanged view retains the completed occlusion result")
	turned:=projection*rl.MatrixLookAt({},{0,0,1},{0,1,0})
	turned_frustum:=r3d.ComputeFrustum(turned)
	prepare_occlusion_view(ctx,&w,nil,{},turned,&turned_frustum,1,320,320)
	testing.expect(t,ctx.occlusion.count==1 && ctx.static_meshes[back].occlusion_faces_ready && ctx.static_meshes[back].occlusion_opaque,"rotation prepares a previously hidden blocker when it becomes visible")
	testing.expect(t,!ctx.static_meshes[front].occlusion_eligible && !ctx.static_meshes[target].occluded,"rotation clears old offscreen visibility flags instead of carrying stale culls")
	// A failed broad-phase frustum must fall back to the unchanged face proof.
	invalid:=frustum;invalid.planes[0][0]=math.nan_f32()
	prepare_occlusion_view(ctx,&w,nil,{},projection,&invalid,1,320,320)
	testing.expect(t,!occlusion_frustum_valid(&invalid) && ctx.occlusion.count==2 && ctx.static_meshes[target].occluded,"invalid frustum data fails open without changing the original projected-face proof")
	bad_bounds:=ctx.static_meshes[front].bounds;bad_bounds.min[0]=math.inf_f32(1)
	testing.expect(t,occlusion_bounds_in_frustum(&frustum,bad_bounds) && occlusion_bounds_in_frustum(nil,ctx.static_meshes[back].bounds),"unusable bounds or a missing frustum cannot become a new rejection")
}
