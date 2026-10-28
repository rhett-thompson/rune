package r3d_bridge

import "core:math/linalg"
import "core:mem"
import "rune:jobs"
import "rune:terrain"
import r3d "r3d:r3d"
import rl "vendor:raylib"

// Limit transient geometry independently of the queue/terrain dimensions.
Terrain_Chunk_Job_Wave :: 8

Terrain_Chunk_CPU :: struct {
	vertices: []r3d.Vertex,
	indices: []u32,
	allocator: mem.Allocator,
}

destroy_terrain_chunk_cpu :: proc(chunk: ^Terrain_Chunk_CPU) {
	delete(chunk.vertices,chunk.allocator); delete(chunk.indices,chunk.allocator)
	chunk^ = {}
}

// Pure CPU construction. Inputs are borrowed through the batch barrier;
// output buffers own persistent allocations, never worker scratch.
build_terrain_chunk_cpu :: proc(data: terrain.Data, start_x,start_z,cells_x,cells_z: int) -> Terrain_Chunk_CPU {
	w,h := cells_x+1,cells_z+1
	result := Terrain_Chunk_CPU{vertices=make([]r3d.Vertex,w*h),indices=make([]u32,cells_x*cells_z*6),allocator=context.allocator}
	d := data.description
	for z in 0..<h {for x in 0..<w {
		gx,gz := start_x+x,start_z+z
		n := terrain.normal(data,gx,gz)
		t := linalg.normalize([3]f32{n[1],-n[0],0})
		result.vertices[z*w+x] = r3d.MakeVertex(terrain.position(data,gx,gz),
			{f32(gx)/f32(d.resolution[0]-1)*d.uv_scale[0],f32(gz)/f32(d.resolution[1]-1)*d.uv_scale[1]},
			n,{t[0],t[1],t[2],-1},rl.WHITE)
	}}
	i := 0
	for z in 0..<cells_z {for x in 0..<cells_x {for index in terrain.cell_indices(x,z,w) {result.indices[i]=index; i+=1}}}
	return result
}

// Graphics calls run only on the owning render thread after jobs finish.
upload_terrain_chunk_cpu :: proc(chunk: Terrain_Chunk_CPU) -> (r3d.Mesh,bool) {
	mesh := r3d.LoadMesh(.TRIANGLES,{vertices=raw_data(chunk.vertices),indices=raw_data(chunk.indices),
		vertexCount=i32(len(chunk.vertices)),indexCount=i32(len(chunk.indices)),
		vertexCapacity=i32(len(chunk.vertices)),indexCapacity=i32(len(chunk.indices))},nil)
	return mesh,r3d.IsMeshValid(mesh)
}

Terrain_Chunk_Work :: struct {
	data: terrain.Data,
	offset, columns: int,
	chunks: [Terrain_Chunk_Job_Wave]Terrain_Chunk_CPU,
}

prepare_terrain_chunk_job :: proc(index: int, pointer: rawptr) {
	work := (^Terrain_Chunk_Work)(pointer)
	d := work.data.description
	i := work.offset+index
	x,z := (i%work.columns)*d.chunk_cells,(i/work.columns)*d.chunk_cells
	work.chunks[index] = build_terrain_chunk_cpu(work.data,x,z,
		min(d.chunk_cells,d.resolution[0]-1-x),min(d.chunk_cells,d.resolution[1]-1-z))
}

upload_terrain_chunks :: proc(ctx: ^Context, cache: ^Terrain_Cache, data: terrain.Data) -> bool {
	d := data.description
	columns := (d.resolution[0]-2+d.chunk_cells)/d.chunk_cells
	rows := (d.resolution[1]-2+d.chunk_cells)/d.chunk_cells
	for offset := 0; offset < columns*rows; offset += Terrain_Chunk_Job_Wave {
		count := min(Terrain_Chunk_Job_Wave,columns*rows-offset)
		work := Terrain_Chunk_Work{data=data,offset=offset,columns=columns}
		started := rl.GetTime()
		jobs.parallel_for(ctx.worker_pool,count,prepare_terrain_chunk_job,&work)
		ctx.frame_stats.terrain_prepare_cpu_ms += (rl.GetTime()-started)*1000
		ctx.frame_stats.terrain_chunks_built += count
		if ctx.worker_pool != nil && count > 1 {ctx.frame_stats.terrain_job_batches += 1}
		// Gather in the original Z/X order. Every result is released even if a
		// GPU allocation fails; the caller retains the last working cache.
		started = rl.GetTime()
		ok := true
		for index in 0..<count {
			chunk := &work.chunks[index]
			if ok {
				mesh,valid := upload_terrain_chunk_cpu(chunk^)
				if valid {append(&cache.chunks,mesh)} else {ok=false}
			}
			destroy_terrain_chunk_cpu(chunk)
		}
		ctx.frame_stats.terrain_upload_cpu_ms += (rl.GetTime()-started)*1000
		if !ok {return false}
	}
	return true
}
