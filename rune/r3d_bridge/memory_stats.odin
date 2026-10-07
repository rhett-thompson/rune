package r3d_bridge

import "rune:memory"
import "rune:terrain"
import r3d "r3d:r3d"

Memory_Stats :: struct {
	static_meshes, models, materials, pooled_instance_buffers: int,
	cache_map_bytes, cache_array_bytes, occlusion_face_bytes, retained_path_bytes: u64,
	mesh_gpu_bytes_estimate, instance_gpu_bytes_estimate: u64,
}

@(private)
mesh_bytes_estimate :: proc(mesh: r3d.Mesh) -> u64 {
	return u64(max(0, mesh.vertexCapacity))*size_of(r3d.Vertex) + u64(max(0, mesh.indexCapacity))*size_of(u32)
}

@(private)
instance_bytes_estimate :: proc(buffer: r3d.InstanceBuffer) -> u64 {
	components := [5]u64{3,4,3,4,4}
	bytes: u64
	for format, index in buffer.layout.formats {
		if buffer.buffers[index] == 0 {continue}
		width: u64
		#partial switch format {
		case .FLOAT32: width = 4
		case .FLOAT16, .UNORM16, .SNORM16: width = 2
		case .UNORM8, .SNORM8: width = 1
		}
		bytes += u64(max(0, buffer.capacity))*components[index]*width
	}
	return bytes
}

// On-demand payload estimates. Excludes backend render targets, shadow maps,
// shaders, imported texture payloads, GPU allocator slack, and driver overhead.
memory_stats :: proc(ctx: ^Context) -> Memory_Stats {
	if ctx == nil {return {}}
	result := Memory_Stats{
		static_meshes = len(ctx.static_meshes), models = len(ctx.models), materials = len(ctx.r3d_materials),
		pooled_instance_buffers = len(ctx.prop_buffer_pool),
	}
	result.cache_map_bytes = memory.map_bytes(ctx.static_meshes) + memory.map_bytes(ctx.static_nodes) + memory.map_bytes(ctx.static_groups)
	result.cache_map_bytes += memory.map_bytes(ctx.render_cache.entries) + memory.map_bytes(ctx.render_cache.nodes)
	result.cache_map_bytes += memory.map_bytes(ctx.prop_batches) + memory.map_bytes(ctx.prop_sources) + memory.map_bytes(ctx.models)
	result.cache_map_bytes += memory.map_bytes(ctx.r3d_materials) + memory.map_bytes(ctx.retained_paths) + memory.map_bytes(ctx.terrains)
	result.cache_array_bytes = u64((cap(ctx.render_cache.planes) + cap(ctx.render_cache.others))*size_of(u64))
	result.cache_array_bytes += u64(cap(ctx.prop_buffer_pool)*size_of(r3d.InstanceBuffer))
	for path in ctx.retained_paths {result.retained_path_bytes += u64(len(path))}
	for _, cache in ctx.static_meshes {
		result.mesh_gpu_bytes_estimate += mesh_bytes_estimate(cache.mesh)
		result.occlusion_face_bytes += u64(len(cache.occlusion_faces)*size_of(Occlusion_Face))
	}
	for _, group in ctx.static_groups {result.cache_array_bytes += u64(cap(group.members)*size_of(u64))}
	for _, batch in ctx.prop_batches {
		result.cache_array_bytes += u64((cap(batch.roots) + cap(batch.pending))*size_of(Prop_Root))
		result.instance_gpu_bytes_estimate += instance_bytes_estimate(batch.buffer)
	}
	for buffer in ctx.prop_buffer_pool {result.instance_gpu_bytes_estimate += instance_bytes_estimate(buffer)}
	for _, cache in ctx.terrains {
		result.cache_array_bytes += u64(cap(cache.chunks)*size_of(r3d.Mesh) + cap(cache.details)*size_of(Terrain_Detail_Batch))
		for mesh in cache.chunks {result.mesh_gpu_bytes_estimate += mesh_bytes_estimate(mesh)}
		for batch in cache.details {
			result.cache_array_bytes += u64(cap(batch.instances)*size_of(terrain.Detail_Instance))
			result.instance_gpu_bytes_estimate += instance_bytes_estimate(batch.buffer)
		}
	}
	for _, asset in ctx.models {
		for index in 0..<int(asset.model.meshCount) {result.mesh_gpu_bytes_estimate += mesh_bytes_estimate(asset.model.meshes[index])}
	}
	for mesh in ([8]r3d.Mesh{ctx.cube,ctx.cube_no_shadow,ctx.plane,ctx.plane_no_shadow,ctx.quad,ctx.quad_no_shadow,ctx.sphere,ctx.sphere_no_shadow}) {
		result.mesh_gpu_bytes_estimate += mesh_bytes_estimate(mesh)
	}
	for mesh in ctx.detail_meshes {result.mesh_gpu_bytes_estimate += mesh_bytes_estimate(mesh)}
	return result
}
