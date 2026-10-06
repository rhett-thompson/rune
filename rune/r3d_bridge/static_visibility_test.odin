package r3d_bridge

import "core:testing"
import "rune:ecs"
import r3d "r3d:r3d"
import rl "vendor:raylib"

@(test)
static_cache_tracks_parent_edits_activation_and_reparenting :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	parent:=ecs.create_entity(&w); ecs.add(&w,&r,parent,ecs.Transform{position={2,0,0},scale={2,1,1}})
	other:=ecs.create_entity(&w); ecs.add(&w,&r,other,ecs.Transform{position={10,0,0},scale={1,1,1}})
	a:=ecs.create_entity(&w); b:=ecs.create_entity(&w)
	for entity in ([2]ecs.Entity{a,b}) {
		ecs.add(&w,&r,entity,ecs.Transform{position={0,0,-5},scale={1,1,1}})
		ecs.set_parent(&w,entity,parent)
	}
	ctx:=Context{static_meshes=make(map[ecs.Entity]Static_Mesh_Cache)}
	defer {
		for _,group in ctx.static_groups {delete(group.members)}
		delete(ctx.static_groups); delete(ctx.static_nodes); delete(ctx.static_meshes)
	}
	for entity in ([2]ecs.Entity{a,b}) {ctx.static_meshes[entity]={mesh=r3d.Mesh{aabb={{-1,-1,-1},{1,1,1}}}}}
	prepare_static_groups(&ctx,&w)
	testing.expect(t,len(ctx.static_groups)==1 && len(ctx.static_groups[parent].members)==2)
	testing.expect(t,ctx.frame_stats.static_transform_nodes==3,"shared ancestry is checked once")
	testing.expect(t,ctx.frame_stats.static_bounds_rebuilt==2)
	testing.expect(t,ctx.static_meshes[a].pose==ecs.Transform{position={2,0,-5},scale={2,1,1}})
	ctx.frame_stats={}; prepare_static_groups(&ctx,&w)
	testing.expect(t,ctx.frame_stats.static_bounds_rebuilt==0,"unchanged geometry reuses matrices and bounds")
	// Public world-map edits must not require special cache invalidation.
	w.transforms[parent]=ecs.Transform{position={4,3,0},rotation={0,90,0},scale={1,2,1}}
	ctx.frame_stats={}; prepare_static_groups(&ctx,&w)
	testing.expect(t,ctx.frame_stats.static_bounds_rebuilt==2 && ctx.static_meshes[a].pose.position==[3]f32{4,3,-5})
	expected,_:=ecs.terrain_transform(&w,a)
	testing.expect(t,ctx.static_meshes[a].pose==expected,"cache uses Rune's hierarchy semantics")
	ecs.set_enabled(&w,parent,false); ctx.frame_stats={}; prepare_static_groups(&ctx,&w)
	testing.expect(t,ctx.frame_stats.static_enabled==0 && len(ctx.static_groups)==0)
	ecs.set_parent(&w,b,other); ctx.frame_stats={}; prepare_static_groups(&ctx,&w)
	testing.expect(t,ctx.frame_stats.static_enabled==1 && len(ctx.static_groups)==1 && len(ctx.static_groups[other].members)==1)
	testing.expect(t,ctx.static_meshes[b].pose.position==[3]f32{10,0,-5})
	ecs.set_enabled(&w,parent,true); ctx.frame_stats={}; prepare_static_groups(&ctx,&w)
	testing.expect(t,ctx.frame_stats.static_enabled==2 && len(ctx.static_groups)==2)
	w.transforms[other]=ecs.Transform{scale={0,1,1}}
	ctx.frame_stats={}; prepare_static_groups(&ctx,&w)
	testing.expect(t,ctx.frame_stats.static_enabled==1 && !ctx.static_meshes[b].valid,"invalid scales never enter a cluster")
	ecs.destroy_entity(&w,a); delete_key(&ctx.static_meshes,a)
	ctx.frame_stats={}; prepare_static_groups(&ctx,&w)
	testing.expect(t,len(ctx.static_groups)==0)
	_,retained:=ctx.static_nodes[a]; testing.expect(t,!retained,"deleted nodes are pruned")
}

@(test)
static_bounds_enclose_rotated_scaled_flat_surfaces :: proc(t:^testing.T) {
	local:=rl.BoundingBox{{-2,-1,0},{2,1,0}}
	pose:=ecs.Transform{position={5,3,-8},rotation={20,65,30},scale={2,3,0.5}}
	transform:=detail_transform(pose)
	bounds:=static_world_bounds(local,transform)
	for i in 0..<8 {
		point:=rl.Vector3Transform({local.max.x if i&1!=0 else local.min.x,
			local.max.y if i&2!=0 else local.min.y,local.max.z if i&4!=0 else local.min.z},transform)
		for axis in 0..<3 {testing.expect(t,point[axis]>bounds.min[axis] && point[axis]<bounds.max[axis],"all transformed corners fit inside the padded bounds")}
	}
}
