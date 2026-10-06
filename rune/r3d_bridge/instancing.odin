package r3d_bridge

import "core:math"
import "rune:assets"
import "rune:ecs"
import r3d "r3d:r3d"
import rl "vendor:raylib"

Prop_Cell_Size :: f32(32)
Prop_Batch_Key :: struct {
	mesh: r3d.Mesh,
	material: r3d.Material,
	scale: rl.Vector3,
	cell: [3]i64,
	pass: Render_Pass,
}
Prop_Root :: struct {position:rl.Vector3,rotation:rl.Quaternion}
Prop_Source :: struct {pose:ecs.Transform,signature:u64,enabled,instanced:bool}
Prop_Batch :: struct {
	roots,pending: [dynamic]Prop_Root,
	buffer: r3d.InstanceBuffer,
	bounds: rl.BoundingBox,
	used: bool,
}

release_prop_batches :: proc(ctx:^Context) {
	for _,batch in ctx.prop_batches {
		if batch.buffer.capacity>0 {append(&ctx.prop_buffer_pool,batch.buffer)}
		delete(batch.roots); delete(batch.pending)
	}
	delete(ctx.prop_batches); ctx.prop_batches=nil
	delete(ctx.prop_sources); ctx.prop_sources=nil; ctx.prop_batches_ready=false
}

prepare_prop_sources :: proc(ctx:^Context,w:^ecs.World,manager:^assets.Asset_Manager) -> bool {
	// Snapshot inexpensive authored values instead of resolving materials and
	// hashing full native mesh/material batch keys on every stationary frame.
	dirty:=!ctx.prop_batches_ready || len(ctx.prop_sources)!=len(ctx.render_cache.entries) ||
		ctx.frame_stats.render_list_rebuilds>0 || ctx.prop_source_manager!=manager ||
		ctx.prop_material_revision!=assets.material_asset_revision(manager)
	if ctx.prop_sources==nil {ctx.prop_sources=make(map[ecs.Entity]Prop_Source)}
	for e,entry in ctx.render_cache.entries {
		signature:=u64(14695981039346656037)
		mesh,has_mesh:=ecs.get_mesh_renderer(w,e)
		sphere,has_sphere:=ecs.get_sphere_renderer(w,e)
		model,has_model:=ecs.get_model_renderer(w,e)
		signature=assets.hash_value(signature,has_mesh)
		signature=assets.hash_value(signature,has_sphere)
		signature=assets.hash_value(signature,has_model)
		signature=assets.hash_value(signature,ecs.has_component_data(w,e,"CloudVolume"))
		_,animated:=ecs.get_model_animator(w,e); signature=assets.hash_value(signature,animated)
		if has_mesh {
			signature=assets.hash_string(signature,mesh.primitive); signature=assets.hash_string(signature,mesh.material)
			signature=assets.hash_value(signature,mesh.color); signature=assets.hash_value(signature,mesh.shadows)
		}
		if has_sphere {
			signature=assets.hash_string(signature,sphere.material); signature=assets.hash_value(signature,sphere.radius)
			signature=assets.hash_value(signature,sphere.color); signature=assets.hash_value(signature,sphere.shadows)
		}
		if has_model {
			signature=assets.hash_string(signature,model.model); signature=assets.hash_string(signature,model.material)
			signature=assets.hash_value(signature,model.tint)
			// Overrides are a map: combine per-slot hashes without iteration order.
			overrides:u64
			for slot,path in model.materials {overrides~=assets.hash_string(assets.hash_value(u64(14695981039346656037),slot),path)}
			signature=assets.hash_value(signature,overrides); signature=assets.hash_value(signature,len(model.materials))
			if manager!=nil {signature=assets.hash_value(signature,manager.models[model.model].revision)}
		}
		previous,found:=ctx.prop_sources[e]
		current:=Prop_Source{pose=entry.pose,signature=signature,enabled=ctx.render_cache.nodes[e].enabled,instanced=previous.instanced}
		if !found || current.pose!=previous.pose || current.signature!=previous.signature || current.enabled!=previous.enabled {dirty=true}
		ctx.prop_sources[e]=current
	}
	for e in ctx.prop_sources {if _,found:=ctx.render_cache.entries[e]; !found {delete_key(&ctx.prop_sources,e)}}
	ctx.prop_source_manager=manager; ctx.prop_material_revision=assets.material_asset_revision(manager); ctx.prop_batches_ready=true
	ctx.frame_stats.prop_batches_reused=!dirty
	return dirty
}

release_prop_buffer_pool :: proc(ctx:^Context) {
	for buffer in ctx.prop_buffer_pool {r3d.UnloadInstanceBuffer(buffer)}
	delete(ctx.prop_buffer_pool); ctx.prop_buffer_pool=nil
}

acquire_prop_buffer :: proc(ctx:^Context,capacity:i32) -> r3d.InstanceBuffer {
	// R3D caches VAO bindings by buffer ID. Deleting/recreating a cached ID can
	// retain its old VAO reference, so keep buffer objects alive until shutdown.
	// The pool is bounded by the peak number of concurrent batches; growth
	// reallocates storage in place and keeps the cached bindings valid.
	buffer:r3d.InstanceBuffer
	if len(ctx.prop_buffer_pool)>0 {buffer=pop(&ctx.prop_buffer_pool)}
	if buffer.capacity==0 {buffer=r3d.LoadInstanceBuffer(capacity,{.POSITION,.ROTATION})}
	else if buffer.capacity<capacity {r3d.ResizeInstanceBuffer(&buffer,capacity,false)}
	return buffer
}

begin_prop_batches :: proc(ctx:^Context) {
	if ctx.prop_batches==nil {ctx.prop_batches=make(map[Prop_Batch_Key]Prop_Batch)}
	for _,&batch in ctx.prop_batches {clear(&batch.pending); batch.used=false}
}

instance_material_eligible :: proc(m:r3d.Material) -> bool {
	return m.shader==nil && m.transparencyMode==.DISABLED && m.blendMode==.MIX && m.billboardMode==.DISABLED && m.albedo.color.a==255 &&
		m.depth.mode==.LESS && m.depth.rangeNear==0 && m.depth.rangeFar==1 && m.depth.offsetFactor==0 && m.depth.offsetUnits==0 &&
		m.stencil.mode==.ALWAYS && m.stencil.ref==0 && m.stencil.mask==255 && m.stencil.opFail==.KEEP && m.stencil.opZFail==.KEEP && m.stencil.opPass==.REPLACE
}

prop_batch_key :: proc(mesh:r3d.Mesh,material:r3d.Material,entry:Render_Entry,pass:Render_Pass,scale:rl.Vector3) -> (Prop_Batch_Key,bool) {
	if !instance_material_eligible(material) || !ecs.component_value_valid(entry.pose) {return {},false}
	key:=Prop_Batch_Key{mesh=mesh,material=material,scale=scale,pass=pass}
	for axis in 0..<3 {
		if !(scale[axis]>0) || math.is_inf(scale[axis]) || abs(entry.pose.position[axis])>1e12 {return {},false}
		// Oversized/off-origin meshes stay individually culled rather than
		// stretching a small prop cluster across a large section of the world.
		if max(abs(mesh.aabb.min[axis]),abs(mesh.aabb.max[axis]))*scale[axis]>Prop_Cell_Size {return {},false}
		key.cell[axis]=i64(math.floor(entry.pose.position[axis]/Prop_Cell_Size))
	}
	return key,true
}

queue_prop :: proc(ctx:^Context,key:Prop_Batch_Key,entry:Render_Entry) {
	batch:=ctx.prop_batches[key]
	append(&batch.pending,Prop_Root{entry.pose.position,entry.rotation}); batch.used=true
	ctx.prop_batches[key]=batch
}

instance_entity :: proc(ctx:^Context,w:^ecs.World,manager:^assets.Asset_Manager,e:ecs.Entity,entry:Render_Entry,pass:Render_Pass) -> bool {
	if ecs.has_component_data(w,e,"CloudVolume") {return false}
	mesh_renderer,has_mesh:=ecs.get_mesh_renderer(w,e)
	sphere,has_sphere:=ecs.get_sphere_renderer(w,e)
	model_renderer,has_model:=ecs.get_model_renderer(w,e)
	// Leave multi-renderer entities on the established path, including its
	// early returns between planes and other components.
	if (int(has_mesh)+int(has_sphere)+int(has_model))!=1 {return false}
	if has_model {
		if pass!=.Non_Plane {return false}
		if _,animated:=ecs.get_model_animator(w,e); animated {return false}
		model,loaded:=load_model(ctx,manager,model_renderer.model)
		if !loaded || model.skeleton.boneCount>0 {return false}
		apply_model_materials(ctx,manager,&model,model_renderer)
		// Validate every submesh first: a failed part cannot leave a partially
		// queued model that is then drawn again by the fallback.
		for i:i32=0; i<model.meshCount; i+=1 {
			_,eligible:=prop_batch_key(model.meshes[i],model.materials[model.meshMaterials[i]],entry,pass,entry.pose.scale)
			if !eligible {return false}
		}
		for i:i32=0; i<model.meshCount; i+=1 {
			key,_:=prop_batch_key(model.meshes[i],model.materials[model.meshMaterials[i]],entry,pass,entry.pose.scale)
			queue_prop(ctx,key,entry)
		}
		return true
	}
	mesh:r3d.Mesh; material:r3d.Material; scale:=entry.pose.scale
	if has_sphere {
		if pass!=.Non_Plane {return false}
		mesh=ctx.sphere if sphere.shadows else ctx.sphere_no_shadow
		scale*=sphere.radius
		material=material_from_path(ctx,manager,sphere.material,sphere.color)
	} else {
		switch mesh_renderer.primitive {
		case "cube":
			if pass!=.Non_Plane {return false}
			mesh=ctx.cube if mesh_renderer.shadows else ctx.cube_no_shadow
		case "quad":
			if pass!=.Non_Plane {return false}
			mesh=ctx.quad if mesh_renderer.shadows else ctx.quad_no_shadow
		case "plane":
			if pass!=.Plane_Only {return false}
			mesh=ctx.plane if mesh_renderer.shadows else ctx.plane_no_shadow
		case: return false
		}
		material=material_from_path(ctx,manager,mesh_renderer.material,mesh_renderer.color)
	}
	key,eligible:=prop_batch_key(mesh,material,entry,pass,scale)
	if !eligible {return false}
	queue_prop(ctx,key,entry)
	return true
}

prop_root_transform :: proc(root:Prop_Root,scale:rl.Vector3) -> rl.Matrix {
	return rl.MatrixTranslate(root.position.x,root.position.y,root.position.z)*rl.QuaternionToMatrix(root.rotation)*rl.MatrixScale(scale.x,scale.y,scale.z)
}

draw_prop_batches :: proc(ctx:^Context,pass:Render_Pass,reused:bool=false) {
	if !reused {
		// Reclaim the old membership before allocating its replacement batches.
		for key,batch in ctx.prop_batches {
			if key.pass!=pass || batch.used {continue}
			if batch.buffer.capacity>0 {append(&ctx.prop_buffer_pool,batch.buffer)}
			delete(batch.roots); delete(batch.pending); delete_key(&ctx.prop_batches,key)
		}
	}
	for key,&batch in ctx.prop_batches {
		if key.pass!=pass || !batch.used {continue}
		count:=len(batch.roots) if reused else len(batch.pending)
		changed:=!reused && count!=len(batch.roots)
		if !reused && !changed {for root,i in batch.pending {if root!=batch.roots[i] {changed=true; break}}}
		if changed {
			for root,i in batch.pending {
				bounds:=static_world_bounds(key.mesh.aabb,prop_root_transform(root,key.scale))
				if i==0 {batch.bounds=bounds}
				else {for axis in 0..<3 {batch.bounds.min[axis]=min(batch.bounds.min[axis],bounds.min[axis]); batch.bounds.max[axis]=max(batch.bounds.max[axis],bounds.max[axis])}}
			}
			batch.roots,batch.pending=batch.pending,batch.roots
		}
		if count>=2 {
			if batch.buffer.capacity<i32(count) {
				capacity:=i32(2); for capacity<i32(count) {capacity*=2}
				if batch.buffer.capacity>0 {r3d.ResizeInstanceBuffer(&batch.buffer,capacity,false)}
				else {batch.buffer=acquire_prop_buffer(ctx,capacity)}
				changed=true
			}
			if batch.buffer.capacity>=i32(count) && batch.buffer.buffers[0]!=0 && batch.buffer.buffers[1]!=0 {
				if changed {
					positions:=make([]rl.Vector3,count,context.temp_allocator)
					rotations:=make([]rl.Quaternion,count,context.temp_allocator)
					for root,i in batch.roots {positions[i]=root.position; rotations[i]=root.rotation}
					r3d.UploadInstances(batch.buffer,{.POSITION},0,i32(count),raw_data(positions),true)
					r3d.UploadInstances(batch.buffer,{.ROTATION},0,i32(count),raw_data(rotations),true)
					ctx.frame_stats.instance_uploads+=1
				}
				// Put common scale in the mesh matrix, so normal transforms retain
				// inverse scale. Instance rotation/translation then preserves T*R*S.
				r3d.BeginCluster(batch.bounds)
				r3d.DrawMeshInstancedPro(key.mesh,key.material,batch.buffer,0,i32(count),rl.MatrixScale(key.scale.x,key.scale.y,key.scale.z))
				r3d.EndCluster()
				ctx.frame_stats.instanced_batches+=1; ctx.frame_stats.prop_instances+=count
				ctx.frame_stats.prop_draws_avoided+=count-1; ctx.frame_stats.prop_draws+=1
				continue
			}
		}
		for root in batch.roots {r3d.DrawMeshPro(key.mesh,key.material,prop_root_transform(root,key.scale)); ctx.frame_stats.prop_draws+=1}
	}
}

prune_prop_batches :: proc(ctx:^Context) {
	for key,batch in ctx.prop_batches {
		if batch.used {continue}
		if batch.buffer.capacity>0 {append(&ctx.prop_buffer_pool,batch.buffer)}
		delete(batch.roots); delete(batch.pending); delete_key(&ctx.prop_batches,key)
	}
}
