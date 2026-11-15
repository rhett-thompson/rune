package r3d_bridge

import "core:testing"
import "rune:ecs"
import rl "vendor:raylib"

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

@(test)
render_cache_skips_hidden_clouds_and_keeps_other_renderers :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	ctx:Context; defer release_render_cache(&ctx)

	cloud:=ecs.create_entity(&w)
	cloud_parent:=ecs.create_entity(&w)
	cube:=ecs.create_entity(&w)
	plane:=ecs.create_entity(&w)
	ecs.set_parent(&w,cube,cloud_parent)
	ecs.add(&w,&r,cloud,ecs.Transform{position={1,0,0},scale={1,1,1}})
	ecs.add(&w,&r,cloud_parent,ecs.Transform{position={2,0,0},scale={1,1,1}})
	ecs.add(&w,&r,cube,ecs.Transform{position={0,0,-5},scale={1,1,1}})
	ecs.add(&w,&r,cube,ecs.MeshRenderer{primitive="cube"})
	ecs.add(&w,&r,plane,ecs.MeshRenderer{primitive="plane"})
	for entity in ([4]ecs.Entity{cloud,cloud_parent,cube,plane}) {
		ecs.add(&w,&r,entity,ecs.default_cloud_volume())
	}

	prepare_render_cache(&ctx,&w)
	c:=&ctx.render_cache
	testing.expect(t,len(c.others)==4 && len(c.planes)==1)
	testing.expect(t,ctx.frame_stats.render_entities==4 && ctx.frame_stats.render_transform_nodes==4)
	testing.expect(t,c.entries[cloud].pose.position==[3]f32{1,0,0})

	ctx.cloud_volumes_disabled=true
	ctx.frame_stats={}
	prepare_render_cache(&ctx,&w)
	_,cached_cloud:=c.entries[cloud]
	_,cached_cloud_transform:=c.nodes[cloud]
	testing.expect(t,!cached_cloud && !cached_cloud_transform)
	testing.expect(t,c.entries[plane].mask==Render_Plane && c.entries[cube].mask==Render_Other)
	testing.expect(t,len(c.others)==1 && c.others[0]==cube && len(c.planes)==1 && c.planes[0]==plane)
	testing.expect(t,ctx.frame_stats.render_entities==2 && ctx.frame_stats.render_transform_nodes==3)

	testing.expect(t,ecs.set_transform(&w,cloud,ecs.Transform{position={3,0,0},scale={1,1,1}}))
	testing.expect(t,ecs.set_transform(&w,cloud_parent,ecs.Transform{position={4,0,0},scale={1,1,1}}))
	ctx.frame_stats={}
	prepare_render_cache(&ctx,&w)
	testing.expect(t,ctx.frame_stats.render_list_rebuilds==0 && ctx.frame_stats.render_matrices_rebuilt==1)
	testing.expect(t,c.entries[cube].pose.position==[3]f32{4,0,-5})
	testing.expect(t,ecs.has_component_data(&w,cloud,"CloudVolume"))

	ctx.cloud_volumes_disabled=false
	prepare_render_cache(&ctx,&w)
	testing.expect(t,len(c.others)==4 && len(c.planes)==1)
	testing.expect(t,c.entries[cloud].pose.position==[3]f32{3,0,0})
}

@(test)
render_cache_prepares_surviving_entries_when_membership_changes :: proc(t: ^testing.T) {
	w := ecs.init(); defer ecs.destroy(&w)
	r := ecs.init_registry(); defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	ctx: Context; defer release_render_cache(&ctx)
	parent := ecs.create_entity(&w)
	assert(ecs.add(&w, &r, parent, ecs.default_transform()))
	assert(ecs.add(&w, &r, parent, ecs.MeshRenderer{primitive="plane"}))
	assert(ecs.add(&w, &r, parent, ecs.ModelRenderer{model="unused.obj"}))
	child, removed := ecs.create_entity(&w), ecs.create_entity(&w)
	for entity in ([2]ecs.Entity{child, removed}) {
		assert(ecs.set_parent(&w, entity, parent))
		assert(ecs.add(&w, &r, entity, ecs.Transform{position={1,2,3}, rotation={5,10,15}, scale={1,1,1}}))
		assert(ecs.add(&w, &r, entity, ecs.MeshRenderer{primitive="cube"}))
	}
	prepare_render_cache(&ctx, &w)
	testing.expect(t, len(ctx.render_cache.planes) == 1 && ctx.frame_stats.render_entities == 3,
		"an entity in both passes prepares its transform once")

	assert(ecs.remove_component(&w, parent, "MeshRenderer"))
	assert(ecs.remove_component(&w, removed, "MeshRenderer"))
	assert(ecs.set_transform(&w, parent, ecs.Transform{position={3,2,1}, rotation={30,40,50}, scale={2,3,4}}))
	ctx.frame_stats = {}
	prepare_render_cache(&ctx, &w)
	c := &ctx.render_cache
	_, removed_entry := c.entries[removed]
	_, removed_node := c.nodes[removed]
	testing.expect(t, !removed_entry && !removed_node && len(c.planes) == 0)
	testing.expect(t, len(c.others) == 2 && c.others[0] == parent && c.others[1] == child,
		"the surviving pass keeps hierarchy order after a removal")
	testing.expect(t, ctx.frame_stats.render_list_rebuilds == 1 && ctx.frame_stats.render_entities == 2 &&
		ctx.frame_stats.render_transform_nodes == 2 && ctx.frame_stats.render_matrices_rebuilt == 2)
	entry := c.entries[child]
	pose := ecs.world_transform_3d(&w, child)
	point := rl.Vector3{2,3,4}
	rotation := rotation_quaternion(pose)
	expected := pose.position + rl.Vector3RotateByQuaternion(point * pose.scale, rotation)
	testing.expect(t, entry.pose == pose && entry.rotation == rotation &&
		rl.Vector3Length(rl.Vector3Transform(point, entry.transform) - expected) < 0.001,
		"the cached matrix and quaternion agree for a rotated, nonuniform hierarchy")

	ctx.frame_stats = {}
	prepare_render_cache(&ctx, &w)
	testing.expect(t, ctx.frame_stats.render_list_rebuilds == 0 && ctx.frame_stats.render_matrices_rebuilt == 0,
		"a steady frame reuses the updated lists and matrices")
}
