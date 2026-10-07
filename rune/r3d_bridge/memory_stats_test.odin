package r3d_bridge

import "core:testing"
import "rune:ecs"
import r3d "r3d:r3d"

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
