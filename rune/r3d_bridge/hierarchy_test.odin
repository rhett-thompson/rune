package r3d_bridge

import "core:testing"
import "rune:ecs"
import rl "vendor:raylib"

@(test)
hierarchy_offsets_inherit_scale_then_rotation :: proc(t: ^testing.T) {
	local := ecs.Transform{position={1,2,3}, rotation={0,15,0}, scale={0.5,2,3}}
	for rotation in ([][3]f32{{}, {90,0,0}, {0,90,0}, {0,0,90}, {20,35,50}}) {
		parent := ecs.Transform{position={10,20,30}, rotation=rotation, scale={2,3,4}}
		pose := ecs.compose_transform_3d(parent, local)
		// Compare with the renderer's matrix convention, independently of the
		// composition helper, including order under nonuniform parent scale.
		expected := rl.Vector3Transform(local.position, detail_transform(parent))
		for axis in 0..<3 {testing.expect(t,abs(pose.position[axis]-expected[axis])<0.001)}
		testing.expect(t,pose.rotation==parent.rotation+local.rotation)
		testing.expect(t,pose.scale==[3]f32{1,6,12})
	}
}

@(test)
render_and_static_caches_share_nested_hierarchy_and_live_edits :: proc(t: ^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r)
	testing.expect(t,ecs.register_builtin_components(&r))
	ctx:Context; defer release_render_cache(&ctx)
	root:=ecs.create_entity(&w)
	ecs.add(&w,&r,root,ecs.Transform{position={10,0,0},rotation={0,90,0},scale={2,3,4}})
	gap:=ecs.create_entity(&w); ecs.set_parent(&w,gap,root)
	child:=ecs.create_entity(&w); ecs.set_parent(&w,child,gap)
	ecs.add(&w,&r,child,ecs.Transform{position={1,0,0},rotation={0,90,0},scale={0.5,1,1}})
	leaf:=ecs.create_entity(&w); ecs.set_parent(&w,leaf,child)
	ecs.add(&w,&r,leaf,ecs.Transform{position={0,0,1},scale={1,1,1}})
	ecs.add(&w,&r,leaf,ecs.MeshRenderer{primitive="cube"})
	prepare_render_cache(&ctx,&w)
	pose:=ctx.render_cache.entries[leaf].pose
	expected:=[3]f32{10,0,-6}
	for axis in 0..<3 {testing.expect(t,abs(pose.position[axis]-expected[axis])<0.001)}
	testing.expect(t,pose.scale==[3]f32{1,3,4} && pose.rotation==[3]f32{0,180,0})
	resolved,valid:=ecs.terrain_transform(&w,leaf)
	testing.expect(t,valid && resolved==pose,"picking and collision agree with rendering")
	// Both primitive and static caches use cached_transform_node. Exercise
	// a separate cache to ensure shared transform-less ancestors are retained.
	nodes:=make(map[ecs.Entity]Static_Transform_Node); defer delete(nodes)
	visited:=0
	node:=cached_transform_node(&nodes,1,&w,leaf,&visited)
	testing.expect(t,node.pose==pose && visited==4)
	root_pose:=w.transforms[root]; root_pose.rotation={}; root_pose.scale={3,2,1}; w.transforms[root]=root_pose
	ctx.frame_stats={}; prepare_render_cache(&ctx,&w)
	pose=ctx.render_cache.entries[leaf].pose
	expected={14,0,0}
	for axis in 0..<3 {testing.expect(t,abs(pose.position[axis]-expected[axis])<0.001)}
	node=cached_transform_node(&nodes,2,&w,leaf,&visited)
	testing.expect(t,node.pose==pose && ctx.frame_stats.render_matrices_rebuilt==1)
	ctx.frame_stats={}; prepare_render_cache(&ctx,&w)
	testing.expect(t,ctx.frame_stats.render_matrices_rebuilt==0,"stationary hierarchies reuse matrices")
}

@(test)
scene_query_follows_rotated_scaled_parent_offsets :: proc(t: ^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	parent:=ecs.create_entity(&w)
	ecs.add(&w,&r,parent,ecs.Transform{position={0,0,5},rotation={0,90,0},scale={2,1,1}})
	child:=ecs.create_entity(&w); ecs.set_parent(&w,child,parent)
	ecs.add(&w,&r,child,ecs.Transform{position={2,0,0},scale={1,1,1}})
	ecs.add(&w,&r,child,ecs.MeshRenderer{primitive="cube"})
	hit,found:=scene_raycast(&w,{0,0,-5},{0,0,10})
	testing.expect(t,found && hit.entity==child && abs(hit.point[2])<0.001,"child center moves to z=1 and scaled cube starts at z=0")
	_,found=scene_raycast(&w,{2,0,-5},{0,0,10})
	testing.expect(t,!found,"raw unrotated child offset is no longer pickable")
}
