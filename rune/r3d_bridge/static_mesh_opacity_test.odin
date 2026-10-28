package r3d_bridge

import "core:math"
import "core:testing"
import "rune:ecs"
import r3d "r3d:r3d"
import rl "vendor:raylib"

@(test)
static_mesh_opacity_fades_a_material_copy_and_skips_zero_opacity_draws :: proc(t:^testing.T) {
	base:=r3d.Material{albedo={color={100,140,180,200}},transparencyMode=.DISABLED,blendMode=.MIX}
	faded:=static_mesh_opacity_material(base,0.5)
	testing.expect(t,faded.albedo.color==rl.Color{100,140,180,100} && faded.transparencyMode==.ALPHA)
	testing.expect(t,base.albedo.color.a==200 && base.transparencyMode==.DISABLED,"shared authored materials remain unchanged")
	base.transparencyMode=.PREPASS;base.blendMode=.PREMULTIPLIED_ALPHA;base.emission.energy=4
	faded=static_mesh_opacity_material(base,0.5)
	testing.expect(t,faded.albedo.color==rl.Color{50,70,90,100} && faded.transparencyMode==.PREPASS && faded.emission.energy==2,
		"authored prepass behavior and premultiplied radiance remain consistent")
	w:=ecs.init();defer ecs.destroy(&w)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
	ctx:=new(Context);ctx.static_meshes=make(map[ecs.Entity]Static_Mesh_Cache)
	defer {for _,&cache in ctx.static_meshes {release_occlusion_faces(&cache)};delete(ctx.static_meshes);free(ctx)}
	entity:=occlusion_test_cached_quad(ctx,&w,&r,-3,1)
	assert(ecs.set_static_mesh_opacity(&w,entity,0))
	// This must return before touching any native rendering API, in either path.
	pose:=ecs.default_transform()
	submit_static_mesh(ctx,&w,nil,entity,ctx.static_meshes[entity],rl.Matrix(1))
	submit_static_mesh(ctx,&w,nil,entity,ctx.static_meshes[entity],{},&pose,shadow_only=true)
	testing.expect(t,ctx.frame_stats.static_submitted==0 && ctx.frame_stats.static_triangles_submitted==0)
}

@(test)
static_mesh_opacity_invalidates_cached_occlusion_without_rebuilding_geometry :: proc(t:^testing.T) {
	w:=ecs.init();defer ecs.destroy(&w)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);assert(ecs.register_builtin_components(&r))
	ctx:=new(Context);ctx.static_meshes=make(map[ecs.Entity]Static_Mesh_Cache)
	defer {for _,&cache in ctx.static_meshes {release_occlusion_faces(&cache)};delete(ctx.static_meshes);free(ctx)}
	front:=occlusion_test_cached_quad(ctx,&w,&r,-3,1.2)
	target:=occlusion_test_cached_quad(ctx,&w,&r,-7,0.25)
	projection:=rl.MatrixPerspective(60*math.PI/180,1,0.1,100)
	frustum:=r3d.ComputeFrustum(projection)
	prepare_occlusion_view(ctx,&w,nil,{},projection,&frustum,1,320,320)
	testing.expect(t,ctx.static_meshes[target].occluded)
	revision:=w.static_meshes[front].revision
	assert(ecs.set_static_mesh_opacity(&w,front,0.5))
	prepare_occlusion_view(ctx,&w,nil,{},projection,&frustum,1,320,320)
	testing.expect(t,!ctx.static_meshes[front].occlusion_opaque && !ctx.static_meshes[target].occluded,
		"a newly translucent wall cannot retain a stale proof hiding geometry or lights")
	testing.expect(t,w.static_meshes[front].revision==revision && ctx.frame_stats.static_uploads==0)
	assert(ecs.set_static_mesh_opacity(&w,front,1))
	prepare_occlusion_view(ctx,&w,nil,{},projection,&frustum,1,320,320)
	testing.expect(t,ctx.static_meshes[target].occluded,"fully opaque surfaces can occlude again")
}
