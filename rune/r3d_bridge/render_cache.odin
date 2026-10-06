package r3d_bridge

import "rune:assets"
import "rune:ecs"
import rl "vendor:raylib"

Render_Plane :: u8(1)
Render_Other :: u8(2)
Render_Entry :: struct {
	mask,next_mask: u8,
	pose: ecs.Transform,
	transform: rl.Matrix,
	rotation: rl.Quaternion,
	prepared: bool,
}
Render_Cache :: struct {
	generation: u32,
	frame,hierarchy_version: u64,
	entries: map[ecs.Entity]Render_Entry,
	nodes: map[ecs.Entity]Static_Transform_Node,
	planes,others: [dynamic]ecs.Entity,
}

release_render_cache :: proc(ctx:^Context) {
	release_prop_batches(ctx)
	c:=&ctx.render_cache
	delete(c.entries); delete(c.nodes); delete(c.planes); delete(c.others)
	c^={}
}

mark_render_entity :: proc(c:^Render_Cache,e:ecs.Entity,mask:u8) {
	entry:=c.entries[e]; entry.next_mask|=mask; c.entries[e]=entry
}

append_render_tree :: proc(c:^Render_Cache,w:^ecs.World,e:ecs.Entity) {
	entry:=c.entries[e]
	mask:=entry.mask
	if mask&Render_Plane!=0 {append(&c.planes,e)}
	if mask&Render_Other!=0 {append(&c.others,e)}
	for child in ecs.child_entities(w,e) {append_render_tree(c,w,child)}
}

prepare_render_cache :: proc(ctx:^Context,w:^ecs.World) {
	c:=&ctx.render_cache
	if c.generation!=w.generation || c.entries==nil {
		release_render_cache(ctx)
		c.generation=w.generation
		c.entries=make(map[ecs.Entity]Render_Entry)
		c.nodes=make(map[ecs.Entity]Static_Transform_Node)
	}
	c.frame+=1
	for _,&entry in c.entries {entry.next_mask=0}
	// Inspect renderer membership only. Public map edits and primitive changes
	// are detected without traversing cameras, physics, audio, or gameplay nodes.
	for e,mesh in w.mesh_renderers {
		switch mesh.primitive {
		case "plane": mark_render_entity(c,e,Render_Plane)
		case "cube","quad": mark_render_entity(c,e,Render_Other)
		}
	}
	for e in w.sphere_renderers {mark_render_entity(c,e,Render_Other)}
	for e in w.model_renderers {mark_render_entity(c,e,Render_Other)}
	if clouds,found:=w.component_data["CloudVolume"]; found {for e in clouds {mark_render_entity(c,e,Render_Other)}}
	roots:=ecs.root_entities(w)
	dirty:=c.hierarchy_version!=w.hierarchy_version
	for e,&entry in c.entries {
		if entry.mask!=entry.next_mask {dirty=true}
		entry.mask=entry.next_mask
		if entry.mask==0 {delete_key(&c.entries,e)}
	}
	if dirty {
		clear(&c.planes); clear(&c.others)
		for root in roots {append_render_tree(c,w,root)}
		c.hierarchy_version=w.hierarchy_version
		ctx.frame_stats.render_list_rebuilds+=1
	}
	for e,&entry in c.entries {
		node:=cached_transform_node(&c.nodes,c.frame,w,e,&ctx.frame_stats.render_transform_nodes)
		if !node.enabled {continue}
		ctx.frame_stats.render_entities+=1
		if !entry.prepared || entry.pose!=node.pose {
			entry.pose=node.pose; entry.transform=detail_transform(node.pose); entry.prepared=true
			entry.rotation=rotation_quaternion(node.pose)
			ctx.frame_stats.render_matrices_rebuilt+=1
		}
	}
	for e,node in c.nodes {if node.frame!=c.frame {delete_key(&c.nodes,e)}}
}

draw_cached_entities :: proc(ctx:^Context,w:^ecs.World,manager:^assets.Asset_Manager) {
	prepare_render_cache(ctx,w)
	batch_rebuild:=ctx.instancing_enabled && prepare_prop_sources(ctx,w,manager)
	if batch_rebuild {begin_prop_batches(ctx)}
	for e in ctx.render_cache.planes {
		if !ctx.render_cache.nodes[e].enabled {continue}
		entry:=ctx.render_cache.entries[e]
		if ctx.instancing_enabled {
			source:=ctx.prop_sources[e]
			if batch_rebuild {source.instanced=instance_entity(ctx,w,manager,e,entry,.Plane_Only); ctx.prop_sources[e]=source}
			if source.instanced {continue}
		}
		draw_entity(ctx,w,manager,e,entry.pose,.Plane_Only,&entry.transform)
	}
	if ctx.instancing_enabled {draw_prop_batches(ctx,.Plane_Only,!batch_rebuild)}
	for e in ctx.render_cache.others {
		if !ctx.render_cache.nodes[e].enabled {continue}
		entry:=ctx.render_cache.entries[e]
		if ctx.instancing_enabled {
			source:=ctx.prop_sources[e]
			if batch_rebuild {source.instanced=instance_entity(ctx,w,manager,e,entry,.Non_Plane); ctx.prop_sources[e]=source}
			if source.instanced {continue}
		}
		draw_entity(ctx,w,manager,e,entry.pose,.Non_Plane,&entry.transform)
	}
	if ctx.instancing_enabled {draw_prop_batches(ctx,.Non_Plane,!batch_rebuild); if batch_rebuild {prune_prop_batches(ctx)}}
}
