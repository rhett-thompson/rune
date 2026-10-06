package r3d_bridge

import "rune:ecs"
import rl "vendor:raylib"

// Submission counts describe bridge work, before R3D's camera/shadow tests.
// CPU timings are wall time; gpu_* fields are delayed timestamp measurements.
Render_Stats :: struct {
	scene_cpu_ms, static_cpu_ms, backend_cpu_ms: f64,
	static_meshes, static_enabled, static_uploads: int,
	static_submitted, static_triangles_submitted: int,
	static_clusters, static_clusters_outside_view, static_meshes_skipped: int,
	static_transform_nodes, static_bounds_rebuilt: int,
	occlusion_tests, occlusion_occluders, static_meshes_occluded: int,
	static_shadow_only, static_scene_triangles_avoided: int,
	occlusion_cpu_ms: f64,
	occlusion_cache_reused: bool,
	local_lights, local_lights_occluded, local_shadow_lights_occluded: int,
	light_occlusion_tests: int,
	light_occlusion_cpu_ms: f64,
	render_entities, render_list_rebuilds, render_transform_nodes, render_matrices_rebuilt: int,
	material_requests, material_hashes, material_cache_hits: int,
	light_properties_updated: int,
	prop_draws, instanced_batches, prop_instances, prop_draws_avoided, instance_uploads: int,
	prop_batches_reused: bool,
	gpu_supported,gpu_ready: bool,
	gpu_backend_ms: f64,
	gpu_sample_frame,gpu_sample_age_frames,gpu_samples: u64,
}

Static_Transform_Node :: struct {
	frame, version, parent_version: u64,
	parent: ecs.Entity,
	local, pose: ecs.Transform,
	has_transform, locally_enabled, enabled: bool,
}

Static_Draw_Group :: struct {
	members: [dynamic]ecs.Entity,
	bounds: rl.BoundingBox,
	shadows: bool,
}

// Check each shared ancestor once per draw. Input comparisons also catch direct
// edits to the public maps; no renderer-specific dirty calls are required.
static_transform_node :: proc(ctx:^Context,world:^ecs.World,entity:ecs.Entity) -> Static_Transform_Node {
	return cached_transform_node(&ctx.static_nodes,ctx.static_frame,world,entity,&ctx.frame_stats.static_transform_nodes)
}

cached_transform_node :: proc(nodes:^map[ecs.Entity]Static_Transform_Node,frame:u64,world:^ecs.World,entity:ecs.Entity,visited:^int) -> Static_Transform_Node {
	node,present:=nodes^[entity]
	if present && node.frame==frame {return node}
	parent:=world.parents[entity]
	ancestor:=Static_Transform_Node{pose=ecs.Transform{scale={1,1,1}},enabled=true}
	if parent!=0 {ancestor=cached_transform_node(nodes,frame,world,parent,visited)}
	local,has_transform:=world.transforms[entity]
	locally_enabled:=ecs.is_locally_enabled(world,entity)
	if !present || node.parent!=parent || node.parent_version!=ancestor.version ||
	   node.local!=local || node.has_transform!=has_transform || node.locally_enabled!=locally_enabled {
		node.parent=parent; node.parent_version=ancestor.version
		node.local=local; node.has_transform=has_transform; node.locally_enabled=locally_enabled
		node.pose=ancestor.pose
		if has_transform {
			node.pose.position+=local.position
			node.pose.rotation+=local.rotation
			node.pose.scale*=local.scale
		}
		node.enabled=ancestor.enabled && locally_enabled
		node.version+=1
	}
	node.frame=frame
	nodes^[entity]=node
	visited^+=1
	return node
}

static_world_bounds :: proc(local:rl.BoundingBox,transform:rl.Matrix) -> rl.BoundingBox {
	bounds:rl.BoundingBox
	for i in 0..<8 {
		corner:=rl.Vector3{local.max.x if i&1!=0 else local.min.x,
			local.max.y if i&2!=0 else local.min.y,local.max.z if i&4!=0 else local.min.z}
		point:=rl.Vector3Transform(corner,transform)
		if i==0 {bounds={point,point}}
		else {for axis in 0..<3 {bounds.min[axis]=min(bounds.min[axis],point[axis]); bounds.max[axis]=max(bounds.max[axis],point[axis])}}
	}
	// Retain flat surfaces and avoid disagreement at floating-point boundaries.
	for axis in 0..<3 {bounds.min[axis]-=0.001; bounds.max[axis]+=0.001}
	return bounds
}

prepare_static_groups :: proc(ctx:^Context,world:^ecs.World) {
	ctx.static_frame+=1
	if ctx.static_nodes==nil {ctx.static_nodes=make(map[ecs.Entity]Static_Transform_Node)}
	if ctx.static_groups==nil {ctx.static_groups=make(map[ecs.Entity]Static_Draw_Group)}
	for _,&group in ctx.static_groups {clear(&group.members); group.shadows=false}
	for entity,&cache in ctx.static_meshes {
		node:=static_transform_node(ctx,world,entity)
		if cache.node_version!=node.version {
			ctx.occlusion.dirty=true
			cache.node_version=node.version
			cache.enabled=node.enabled
			cache.valid=node.has_transform && ecs.component_value_valid(node.pose)
			for scale in node.pose.scale {if !(scale>0) {cache.valid=false}}
		}
		if !cache.enabled || !cache.valid {continue}
		ctx.frame_stats.static_enabled+=1
		if !cache.pose_cached || cache.pose!=node.pose {
			cache.pose=node.pose; cache.pose_cached=true
			cache.transform=detail_transform(node.pose)
			cache.bounds=static_world_bounds(cache.mesh.aabb,cache.transform)
			ctx.frame_stats.static_bounds_rebuilt+=1
		}
		cache.shadows=true
		if renderer,found:=ecs.get_mesh_renderer(world,entity); found && renderer.primitive=="static" {cache.shadows=renderer.shadows}
		key:=world.parents[entity]
		if key==0 {key=entity}
		group,found:=ctx.static_groups[key]
		if !found {group.members=make([dynamic]ecs.Entity)}
		if len(group.members)==0 {group.bounds=cache.bounds}
		else {for axis in 0..<3 {group.bounds.min[axis]=min(group.bounds.min[axis],cache.bounds.min[axis]); group.bounds.max[axis]=max(group.bounds.max[axis],cache.bounds.max[axis])}}
		group.shadows=group.shadows || cache.shadows
		append(&group.members,entity)
		ctx.static_groups[key]=group
	}
	// Prune unused ancestors and groups without retaining deleted scene data.
	removed:=make([dynamic]ecs.Entity,context.temp_allocator)
	for entity,node in ctx.static_nodes {if node.frame!=ctx.static_frame {append(&removed,entity)}}
	for entity in removed {delete_key(&ctx.static_nodes,entity)}
	clear(&removed)
	for entity,group in ctx.static_groups {if len(group.members)==0 {append(&removed,entity)}}
	for entity in removed {delete(ctx.static_groups[entity].members); delete_key(&ctx.static_groups,entity)}
}
