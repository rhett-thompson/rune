package geometry

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
surface_chunks :: proc(volume: Volume, colors: [][4]u8, chunk_size: [3]int) -> ([dynamic]Mesh_Chunk,bool) {
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
	for z in first[2]..<last[2] {for y in first[1]..<last[1] {for x in first[0]..<last[0] {
		coordinate:=[3]int{x,y,z}
		a,b:[3]int
		for axis in 0..<3 {a[axis]=max(low[axis],coordinate[axis]*chunk_size[axis]); b[axis]=min(high[axis],(coordinate[axis]+1)*chunk_size[axis])}
		mesh:=surface_region_unchecked(volume,colors,a,b)
		if len(mesh.indices)==0 {destroy_mesh(&mesh); continue}
		// Metadata describes the logical chunk, even when occupied bounds shrink
		// extraction. Partial chunks at the volume edge are clipped to its size.
		for axis in 0..<3 {a[axis]=coordinate[axis]*chunk_size[axis]; b[axis]=min(volume.size[axis],(coordinate[axis]+1)*chunk_size[axis])}
		append(&chunks,Mesh_Chunk{coordinate,a,b,mesh})
	}}}
	return chunks,len(chunks)>0
}
