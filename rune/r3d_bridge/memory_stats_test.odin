package r3d_bridge

import "core:testing"
import "core:mem"
import "rune:ecs"
import r3d "r3d:r3d"
import rl "vendor:raylib"

@(test)
memory_stats_count_mesh_capacity_and_active_and_pooled_instances :: proc(t: ^testing.T) {
	ctx := Context{static_meshes = make(map[ecs.Entity]Static_Mesh_Cache), prop_batches = make(map[Prop_Batch_Key]Prop_Batch)}
	defer delete(ctx.static_meshes)
	defer delete(ctx.prop_batches)
	defer delete(ctx.prop_buffer_pool)
	// Synthetic buffer descriptions avoid allocating GPU resources.
	ctx.static_meshes[ecs.Entity(1)] = {mesh = {vertexCapacity=24,indexCapacity=36}}
	buffer := r3d.InstanceBuffer{capacity=16,buffers={1,2,0,0,0},layout={flags={.POSITION,.ROTATION}}}
	ctx.prop_batches[{}] = {buffer=buffer}
	append(&ctx.prop_buffer_pool,buffer)
	stats := memory_stats(&ctx)
	testing.expect(t,stats.static_meshes == 1 && stats.pooled_instance_buffers == 1)
	testing.expect(t,stats.mesh_gpu_bytes_estimate == 24*size_of(r3d.Vertex) + 36*size_of(u32))
	testing.expect(t,stats.instance_gpu_bytes_estimate == 2*16*7*size_of(f32))
	testing.expect(t,stats.cache_map_bytes > 0 && stats.cache_array_bytes >= size_of(r3d.InstanceBuffer))
	testing.expect(t,memory_stats(nil).mesh_gpu_bytes_estimate == 0)
}

@(test)
terrain_detail_staging_is_counted_and_released :: proc(t: ^testing.T) {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker,context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	context.allocator=mem.tracking_allocator(&tracker)
	ctx:=Context{terrains=make(map[ecs.Entity]Terrain_Cache)}
	cache:Terrain_Cache
	append(&cache.details,Terrain_Detail_Batch{
		positions=make([]rl.Vector3,10),rotations=make([]rl.Quaternion,10),
		scales=make([]rl.Vector3,10),colors=make([]rl.Color,10),
	})
	ctx.terrains[ecs.Entity(1)]=cache
	expected:=u64(cap(cache.details)*size_of(Terrain_Detail_Batch)+10*(2*size_of(rl.Vector3)+size_of(rl.Quaternion)+size_of(rl.Color)))
	testing.expect(t,memory_stats(&ctx).cache_array_bytes==expected)
	release_terrains(&ctx)
	testing.expect(t,memory_stats(&ctx).cache_array_bytes==0)
	delete(ctx.terrains)
	testing.expect(t,tracker.current_memory_allocated==0,"terrain cache teardown releases every staging allocation")
}
