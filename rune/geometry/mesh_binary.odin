package geometry

import "core:hash/xxhash"

// A portable RGMS v1 stream stores explicit little-endian IEEE f32 values,
// RGBA bytes and u32 indices. It does not persist native struct padding or
// allocators. Empty meshes are supported for optional geometry channels.
MESH_BINARY_VERSION :: u32(1)
MESH_BINARY_HEADER_BYTES :: 24
MESH_BINARY_VERTEX_BYTES :: 28

@(private="package")
mesh_binary_put_u32 :: proc(bytes: []u8, value: u32) {
	for i in 0..<4 {bytes[i]=u8(value>>uint(i*8))}
}

@(private="package")
mesh_binary_get_u32 :: proc(bytes: []u8) -> u32 {
	value: u32
	for i in 0..<4 {value |= u32(bytes[i])<<uint(i*8)}
	return value
}

@(private="package")
mesh_binary_put_u64 :: proc(bytes: []u8, value: u64) {
	for i in 0..<8 {bytes[i]=u8(value>>uint(i*8))}
}

@(private="package")
mesh_binary_get_u64 :: proc(bytes: []u8) -> u64 {
	value: u64
	for i in 0..<8 {value |= u64(bytes[i])<<uint(i*8)}
	return value
}

// The caller owns the bytes and releases them with delete. Invalid input never
// mutates the source mesh. Nonempty meshes use the existing geometry limits.
encode_mesh :: proc(mesh: Mesh) -> ([]u8, string) {
	if !(len(mesh.vertices)==0 && len(mesh.indices)==0) && !valid(mesh) {return nil,"invalid geometry mesh"}
	size:=MESH_BINARY_HEADER_BYTES+len(mesh.vertices)*MESH_BINARY_VERTEX_BYTES+len(mesh.indices)*4
	bytes:=make([]u8,size)
	copy(bytes[:4],"RGMS")
	mesh_binary_put_u32(bytes[4:8],MESH_BINARY_VERSION)
	mesh_binary_put_u32(bytes[8:12],u32(len(mesh.vertices)))
	mesh_binary_put_u32(bytes[12:16],u32(len(mesh.indices)))
	offset:=MESH_BINARY_HEADER_BYTES
	for vertex in mesh.vertices {
		for n in vertex.position {mesh_binary_put_u32(bytes[offset:offset+4],transmute(u32)n);offset+=4}
		for n in vertex.normal {mesh_binary_put_u32(bytes[offset:offset+4],transmute(u32)n);offset+=4}
		for color,i in vertex.color {bytes[offset+i]=color};offset+=4
	}
	for index in mesh.indices {mesh_binary_put_u32(bytes[offset:offset+4],index);offset+=4}
	mesh_binary_put_u64(bytes[16:24],xxhash.XXH3_64(bytes[MESH_BINARY_HEADER_BYTES:]))
	return bytes,""
}

// Counts, exact length and checksum are checked before allocating mesh arrays.
// Successful results own their arrays; destroy_mesh also handles empty meshes.
decode_mesh :: proc(bytes: []u8) -> (Mesh, string) {
	if len(bytes)<MESH_BINARY_HEADER_BYTES || string(bytes[:4])!="RGMS" {return {},"invalid geometry mesh header"}
	if mesh_binary_get_u32(bytes[4:8])!=MESH_BINARY_VERSION {return {},"unsupported geometry mesh version"}
	vertex_count,index_count:=mesh_binary_get_u32(bytes[8:12]),mesh_binary_get_u32(bytes[12:16])
	if vertex_count>1000000 || index_count>6000000 || index_count%3!=0 || (vertex_count==0)!=(index_count==0) {return {},"invalid geometry mesh counts"}
	vertices,indices:=int(vertex_count),int(index_count)
	if len(bytes)!=MESH_BINARY_HEADER_BYTES+vertices*MESH_BINARY_VERTEX_BYTES+indices*4 {return {},"invalid geometry mesh length"}
	if mesh_binary_get_u64(bytes[16:24])!=xxhash.XXH3_64(bytes[MESH_BINARY_HEADER_BYTES:]) {return {},"geometry mesh checksum mismatch"}
	if vertices==0 {return {},""}
	mesh:=Mesh{vertices=make([dynamic]Vertex,vertices),indices=make([dynamic]u32,indices)}
	success:=false
	defer if !success {destroy_mesh(&mesh)}
	offset:=MESH_BINARY_HEADER_BYTES
	for &vertex in mesh.vertices {
		for &n in vertex.position {n=transmute(f32)mesh_binary_get_u32(bytes[offset:offset+4]);offset+=4}
		for &n in vertex.normal {n=transmute(f32)mesh_binary_get_u32(bytes[offset:offset+4]);offset+=4}
		copy(vertex.color[:],bytes[offset:offset+4]);offset+=4
	}
	for &index in mesh.indices {index=mesh_binary_get_u32(bytes[offset:offset+4]);offset+=4}
	if !valid(mesh) {return {},"invalid geometry mesh data"}
	success=true
	return mesh,""
}
