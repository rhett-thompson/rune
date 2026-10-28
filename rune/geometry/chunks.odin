package geometry

import "rune:jobs"

Mesh_Chunk :: struct {
	coordinate, low, high: [3]int, // half-open voxel bounds, anchored at volume index zero
	mesh: Mesh, // positions retain volume origin/spacing; no per-chunk translation
}

destroy_mesh_chunks :: proc(chunks: ^[dynamic]Mesh_Chunk) {
	for &chunk in chunks^ {destroy_mesh(&chunk.mesh)}
	delete(chunks^); chunks^=nil
}

// Deterministic Z/Y/X order, with empty chunks omitted. Validate the volume once
// and merge exposed faces within each chunk while sampling the shared neighbors.
surface_chunks :: proc(volume: Volume, colors: [][4]u8, chunk_size: [3]int, pool: ^jobs.Pool = nil) -> ([dynamic]Mesh_Chunk,bool) {
	low,high,ok:=surface_bounds(volume,colors)
	if !ok {return nil,false}
	first,last:[3]int
	count:=1
	for axis in 0..<3 {
		if chunk_size[axis]<=0 || chunk_size[axis]>1024 {return nil,false}
		first[axis]=low[axis]/chunk_size[axis]
		last[axis]=(high[axis]+chunk_size[axis]-1)/chunk_size[axis]
		count*=last[axis]-first[axis]
	}
	if count>65536 {return nil,false}
	chunks:[dynamic]Mesh_Chunk
	if pool!=nil && count>=4 {
		// Workers read an immutable volume and write one independent slot each.
		// Gather only after the barrier, preserving the serial order exactly.
		results:=make([]Mesh_Chunk,count)
		defer delete(results)
		batch:=Surface_Chunk_Batch{volume,colors,chunk_size,first,last,low,high,results}
		jobs.parallel_for(pool,count,surface_chunk_job,&batch)
		for &chunk in results {
			if len(chunk.mesh.indices)==0 {destroy_mesh(&chunk.mesh);continue}
			append(&chunks,chunk)
		}
		return chunks,len(chunks)>0
	}
	for z in first[2]..<last[2] {for y in first[1]..<last[1] {for x in first[0]..<last[0] {
		coordinate:=[3]int{x,y,z}
		chunk:=surface_chunk_unchecked(volume,colors,chunk_size,coordinate,low,high)
		if len(chunk.mesh.indices)==0 {destroy_mesh(&chunk.mesh);continue}
		append(&chunks,chunk)
	}}}
	return chunks,len(chunks)>0
}

@(private)
Surface_Chunk_Batch :: struct {
	volume:Volume,
	colors:[][4]u8,
	chunk_size,first,last,low,high:[3]int,
	results:[]Mesh_Chunk,
}

@(private)
surface_chunk_job :: proc(index:int,data:rawptr) {
	batch:=(^Surface_Chunk_Batch)(data)
	w,h:=batch.last[0]-batch.first[0],batch.last[1]-batch.first[1]
	coordinate:=batch.first+[3]int{index%w,(index/w)%h,index/(w*h)}
	batch.results[index]=surface_chunk_unchecked(batch.volume,batch.colors,batch.chunk_size,coordinate,batch.low,batch.high)
}

@(private)
surface_chunk_unchecked :: proc(volume:Volume,colors:[][4]u8,chunk_size,coordinate,low,high:[3]int) -> Mesh_Chunk {
	a,b:[3]int
	for axis in 0..<3 {a[axis]=max(low[axis],coordinate[axis]*chunk_size[axis]); b[axis]=min(high[axis],(coordinate[axis]+1)*chunk_size[axis])}
	mesh:=surface_region_unchecked(volume,colors,a,b)
	// Metadata describes the logical chunk, even when occupied bounds shrink
	// extraction. Partial chunks at the volume edge are clipped to its size.
	for axis in 0..<3 {a[axis]=coordinate[axis]*chunk_size[axis]; b[axis]=min(volume.size[axis],(coordinate[axis]+1)*chunk_size[axis])}
	return {coordinate,a,b,mesh}
}
