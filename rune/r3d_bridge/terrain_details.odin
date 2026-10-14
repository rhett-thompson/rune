package r3d_bridge

import "core:math/linalg"
import "core:math"
import "rune:assets"
import "rune:ecs"
import "rune:terrain"
import rl "vendor:raylib"
import r3d "r3d:r3d"

Terrain_Detail_Batch :: struct {
	instances: [dynamic]terrain.Detail_Instance,
	buffer: r3d.InstanceBuffer,
	visible_count:i32,
	positions: []rl.Vector3,
	rotations: []rl.Quaternion,
	scales: []rl.Vector3,
	colors: []rl.Color,
	view: Terrain_Detail_View,
	view_ready: bool,
	cached_visible_count: i32,
	// Conservative movement radius around view.camera in which selection and
	// distance-faded scales cannot change. No per-instance cache is added.
	camera_reuse_radius: f32,
}

// Only values affecting instance streams belong in this key. Descriptor edits
// rebuild the batch; retaining borrowed descriptor strings here is unnecessary.
Terrain_Detail_View :: struct {
	transform: ecs.Transform,
	camera: [3]f32,
	draw_distance: f32,
	grass, align_to_normal: bool,
}

release_detail_batch :: proc(batch:^Terrain_Detail_Batch) {
	if batch.buffer.capacity>0 {r3d.UnloadInstanceBuffer(batch.buffer)}
	delete(batch.instances)
	delete(batch.positions); delete(batch.rotations); delete(batch.scales); delete(batch.colors)
	batch^={}
}

prepare_detail_batches :: proc(cache:^Terrain_Cache,data:terrain.Data) -> bool {
	cache.details=make([dynamic]Terrain_Detail_Batch)
	for detail in data.description.details {
		batch:=Terrain_Detail_Batch{instances=terrain.scatter_details(data,detail)}
		if len(batch.instances)>0 {
			batch.buffer=r3d.LoadInstanceBuffer(i32(len(batch.instances)),{.POSITION,.ROTATION,.SCALE,.COLOR})
			if batch.buffer.capacity!=i32(len(batch.instances)) || batch.buffer.buffers[0]==0 {
				release_detail_batch(&batch); return false
			}
			batch.positions=make([]rl.Vector3,len(batch.instances))
			batch.rotations=make([]rl.Quaternion,len(batch.instances))
			batch.scales=make([]rl.Vector3,len(batch.instances))
			batch.colors=make([]rl.Color,len(batch.instances))
		}
		append(&cache.details,batch)
	}
	return true
}

detail_transform :: proc(t:ecs.Transform) -> rl.Matrix {
	return rl.MatrixTranslate(t.position[0],t.position[1],t.position[2])*
		rl.QuaternionToMatrix(rotation_quaternion(t))*rl.MatrixScale(t.scale[0],t.scale[1],t.scale[2])
}

// Returns true only when packed instance streams change. Camera motion inside
// the cached safe region does no candidate scan or GPU upload. A scan outside
// that region still retains streams when the exact selection/scales are equal.
upload_visible_details :: proc(batch:^Terrain_Detail_Batch,detail:terrain.Detail,t:ecs.Transform,camera:[3]f32) -> bool {
	view:=Terrain_Detail_View{transform=t,camera=camera,draw_distance=detail.draw_distance,
		grass=detail.kind=="grass",align_to_normal=detail.align_to_normal}
	previous:=batch.view
	previous.camera=camera
	static_unchanged:=batch.view_ready && previous==view
	if static_unchanged {
		movement:=camera-batch.view.camera
		if camera==batch.view.camera || len(batch.instances)==0 ||
		   (batch.camera_reuse_radius>0 && linalg.dot(movement,movement)<batch.camera_reuse_radius*batch.camera_reuse_radius) {
			batch.visible_count=batch.cached_visible_count
			return false
		}
	}
	previous_count:=batch.cached_visible_count
	changed:=!static_unchanged
	batch.view=view; batch.view_ready=true
	batch.visible_count=0
	batch.camera_reuse_radius=0
	if len(batch.instances)==0 {batch.cached_visible_count=0; return changed || previous_count!=0}
	transform:=detail_transform(t)
	terrain_rotation:=rotation_quaternion(t)
	// The triangle inequality guarantees that moving less than the nearest
	// boundary distance cannot change any root's inside/outside classification.
	// Built-in grass has a second boundary where smooth fading starts.
	reuse_radius:=math.inf_f32(1)
	fade_start:=detail.draw_distance*0.8
	for instance in batch.instances {
		world:=rl.Vector3Transform(instance.position,transform)
		delta:=world-camera
		distance_squared:=linalg.dot(delta,delta)
		distance:=math.sqrt(distance_squared)
		reuse_radius=min(reuse_radius,abs(distance-detail.draw_distance))
		if view.grass {
			reuse_radius=min(reuse_radius,abs(distance-fade_start))
			// Every moving view changes the scales of roots already in the fade
			// band, so those batches keep exact per-root distance evaluation.
			if distance>=fade_start && distance_squared<detail.draw_distance*detail.draw_distance {reuse_radius=0}
		}
		if distance_squared>=detail.draw_distance*detail.draw_distance {continue}
		i:=int(batch.visible_count)
		// R3D applies its mesh transform BEFORE the instance rotation/scale.
		// Upload world-space roots and draw with an identity mesh transform so
		// random rotation and distance fading can never move a root off terrain.
		if !static_unchanged || i>=int(previous_count) || batch.positions[i]!=world {
			changed=true
			batch.positions[i]=world
			rotation:=rl.QuaternionFromAxisAngle({0,1,0},instance.yaw)
			if detail.align_to_normal {
				// Inverse scale keeps the surface normal correct on stretched terrain.
				normal:=linalg.normalize(instance.normal/t.scale)
				rotation=rl.QuaternionFromVector3ToVector3({0,1,0},normal)*rotation
			}
			batch.rotations[i]=terrain_rotation*rotation
			shade:=u8(instance.shade*255)
			batch.colors[i]={shade,shade,shade,255}
		}
		scale:=instance.scale
		if view.grass {
			// Reduce distant tufts smoothly while keeping their base on the surface.
			fade:=clamp((detail.draw_distance-distance)/(detail.draw_distance*0.2),0,1)
			scale*=fade
		}
		world_scale:=t.scale*scale
		if !static_unchanged || batch.scales[i]!=world_scale {batch.scales[i]=world_scale; changed=true}
		batch.visible_count+=1
	}
	// Leave a small numerical margin and use a strict movement bound: roots on
	// the culling boundary are excluded exactly as in the original draw path.
	batch.camera_reuse_radius=max(f32(0),reuse_radius-max(f32(0.0001),detail.draw_distance*0.00001))
	batch.cached_visible_count=batch.visible_count
	changed=changed || batch.visible_count!=previous_count
	if !changed {return false}
	if batch.visible_count==0 {return true}
	r3d.UploadInstances(batch.buffer,{.POSITION},0,batch.visible_count,raw_data(batch.positions),true)
	r3d.UploadInstances(batch.buffer,{.ROTATION},0,batch.visible_count,raw_data(batch.rotations),true)
	r3d.UploadInstances(batch.buffer,{.SCALE},0,batch.visible_count,raw_data(batch.scales),true)
	r3d.UploadInstances(batch.buffer,{.COLOR},0,batch.visible_count,raw_data(batch.colors),true)
	return true
}

draw_terrain_details :: proc(ctx:^Context,world:^ecs.World,manager:^assets.Asset_Manager,camera:[3]f32) {
	for entity,&cache in ctx.terrains {
		for &batch in cache.details {batch.visible_count=0}
		if !ecs.is_enabled(world,entity) {continue}
		t,ok:=ecs.terrain_transform(world,entity); if !ok {continue}
		data,_,found:=ecs.terrain_runtime(world,entity); if !found {continue}
		for &batch,i in cache.details {
			if i>=len(data.description.details) {continue}
			detail:=data.description.details[i]
			if upload_visible_details(&batch,detail,t,camera) {
				ctx.frame_stats.terrain_detail_rebuilds+=1
				if batch.visible_count>0 {ctx.frame_stats.terrain_detail_uploads+=1}
			}
			if batch.visible_count==0 {continue}
			material:=material_from_path(ctx,manager,detail.material,{255,255,255,255})
			if detail.material=="" {material.orm.roughness=0.9}
			if detail.kind=="model" {
				model,loaded:=load_model(ctx,manager,detail.model); if !loaded {continue}
				for mesh_index:i32=0; mesh_index<model.meshCount; mesh_index+=1 {
					mesh:=model.meshes[mesh_index]
					mesh.shadowCastMode=.ON_DOUBLE_SIDED if detail.shadows else .DISABLED
					r3d.DrawMeshInstanced(mesh,material,batch.buffer,batch.visible_count)
				}
			} else {
				kind:=0 if detail.kind=="grass" else (1 if detail.kind=="tree" else 2)
				if !r3d.IsMeshValid(ctx.detail_meshes[kind]) {ctx.detail_meshes[kind]=make_detail_mesh(kind)}
				mesh:=ctx.detail_meshes[kind]
				if !r3d.IsMeshValid(mesh) {continue}
				mesh.shadowCastMode=.ON_DOUBLE_SIDED if detail.shadows else .DISABLED
				if kind==0 {material.cullMode=.NONE}
				r3d.DrawMeshInstanced(mesh,material,batch.buffer,batch.visible_count)
			}
		}
	}
}
