package r3d_bridge

import "core:testing"
import "rune:assets"
import "rune:ecs"

@(test)
prop_membership_cache_observes_live_sources :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	ctx:Context; defer release_render_cache(&ctx)
	manager:=assets.Asset_Manager{material_revision=1}
	e:=ecs.create_entity(&w)
	ecs.add(&w,&r,e,ecs.Transform{scale={1,1,1}})
	ecs.add(&w,&r,e,ecs.MeshRenderer{primitive="cube",color={255,255,255,255}})
	prepare_render_cache(&ctx,&w)
	testing.expect(t,prepare_prop_sources(&ctx,&w,&manager))
	ctx.frame_stats={}; prepare_render_cache(&ctx,&w)
	testing.expect(t,!prepare_prop_sources(&ctx,&w,&manager) && ctx.frame_stats.prop_batches_reused)
	// Public component maps may be edited without a scene/hierarchy revision.
	mesh:=w.mesh_renderers[e]; mesh.color={100,200,220,255}; w.mesh_renderers[e]=mesh
	testing.expect(t,prepare_prop_sources(&ctx,&w,&manager))
	testing.expect(t,!prepare_prop_sources(&ctx,&w,&manager))
	pose:=w.transforms[e]; pose.position={35,0,0}; w.transforms[e]=pose
	ctx.frame_stats={}; prepare_render_cache(&ctx,&w)
	testing.expect(t,prepare_prop_sources(&ctx,&w,&manager),"crossing a spatial cell invalidates membership")
	ecs.add(&w,&r,e,ecs.SphereRenderer{radius=1,color={255,255,255,255}})
	testing.expect(t,prepare_prop_sources(&ctx,&w,&manager),"adding a second renderer changes eligibility")
	ecs.remove_component(&w,e,"SphereRenderer")
	testing.expect(t,prepare_prop_sources(&ctx,&w,&manager))
	manager.material_revision+=1
	testing.expect(t,prepare_prop_sources(&ctx,&w,&manager),"asset hot reload invalidates resolved keys")
	ecs.set_enabled(&w,e,false); ctx.frame_stats={}; prepare_render_cache(&ctx,&w)
	testing.expect(t,prepare_prop_sources(&ctx,&w,&manager))
	ecs.destroy_entity(&w,e); ctx.frame_stats={}; prepare_render_cache(&ctx,&w)
	testing.expect(t,prepare_prop_sources(&ctx,&w,&manager) && len(ctx.prop_sources)==0)
}
