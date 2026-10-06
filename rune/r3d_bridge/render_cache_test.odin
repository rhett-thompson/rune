package r3d_bridge

import "core:testing"
import "rune:ecs"

@(test)
render_cache_tracks_membership_hierarchy_and_live_transforms :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	ctx:Context; defer release_render_cache(&ctx)
	parent:=ecs.create_entity(&w)
	ecs.add(&w,&r,parent,ecs.Transform{position={2,0,0},scale={2,1,1}})
	child:=ecs.create_entity(&w); ecs.set_parent(&w,child,parent)
	ecs.add(&w,&r,child,ecs.Transform{position={0,0,-5},scale={1,1,1}})
	ecs.add(&w,&r,child,ecs.MeshRenderer{primitive="cube",color={255,255,255,255}})
	for _ in 0..<20 {ecs.create_entity(&w)}
	prepare_render_cache(&ctx,&w)
	testing.expect(t,len(ctx.render_cache.others)==1 && len(ctx.render_cache.planes)==0)
	testing.expect(t,ctx.frame_stats.render_entities==1 && ctx.frame_stats.render_transform_nodes==2,"only renderables and their ancestry are visited")
	testing.expect(t,ctx.render_cache.entries[child].pose.position==[3]f32{2,0,-5})
	ctx.frame_stats={}; prepare_render_cache(&ctx,&w)
	testing.expect(t,ctx.frame_stats.render_list_rebuilds==0 && ctx.frame_stats.render_matrices_rebuilt==0)
	pose:=w.transforms[parent]; pose.position={4,3,0}; w.transforms[parent]=pose
	ctx.frame_stats={}; prepare_render_cache(&ctx,&w)
	testing.expect(t,ctx.frame_stats.render_list_rebuilds==0 && ctx.frame_stats.render_matrices_rebuilt==1)
	testing.expect(t,ctx.render_cache.entries[child].pose.position==[3]f32{4,3,-5})
	// Even a direct primitive edit must move the renderer between passes.
	renderer:=w.mesh_renderers[child]; renderer.primitive="plane"; w.mesh_renderers[child]=renderer
	ctx.frame_stats={}; prepare_render_cache(&ctx,&w)
	testing.expect(t,len(ctx.render_cache.others)==0 && len(ctx.render_cache.planes)==1 && ctx.frame_stats.render_list_rebuilds==1)
	ecs.set_enabled(&w,parent,false); ctx.frame_stats={}; prepare_render_cache(&ctx,&w)
	testing.expect(t,ctx.frame_stats.render_entities==0)
	ecs.set_parent(&w,child,0); ecs.root_entities(&w) // Another system may consume hierarchy_dirty first.
	ctx.frame_stats={}; prepare_render_cache(&ctx,&w)
	testing.expect(t,ctx.frame_stats.render_entities==1 && ctx.frame_stats.render_list_rebuilds==1)
	testing.expect(t,ctx.render_cache.entries[child].pose.position==[3]f32{0,0,-5})
	ecs.remove_component(&w,child,"MeshRenderer"); ctx.frame_stats={}; prepare_render_cache(&ctx,&w)
	testing.expect(t,len(ctx.render_cache.planes)==0 && len(ctx.render_cache.nodes)==0)
	other:=ecs.init(); defer ecs.destroy(&other)
	prepare_render_cache(&ctx,&other)
	testing.expect(t,ctx.render_cache.generation==other.generation && len(ctx.render_cache.entries)==0,"scene replacement releases cached membership")
}
