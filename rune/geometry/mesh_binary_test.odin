package geometry

import "core:hash/xxhash"
import "core:testing"

@(test)
mesh_binary_round_trip_preserves_exact_vertices_and_indices :: proc(t: ^testing.T) {
	volume:=Volume{size={2,1,2},cells=make([]u8,4),spacing=0.25,origin={-3,2,7}}
	defer delete(volume.cells)
	fill_box(volume,{},volume.size,1)
	colors:=[2][4]u8{{},{12,230,84,255}}
	mesh,ok:=surface(volume,colors[:]);testing.expect(t,ok);defer destroy_mesh(&mesh)
	bytes,error:=encode_mesh(mesh);testing.expect(t,error=="");defer delete(bytes)
	testing.expect(t,string(bytes[:4])=="RGMS" && bytes[4]==1 && bytes[5]==0,"format uses a versioned little-endian header")
	loaded,load_error:=decode_mesh(bytes);testing.expect(t,load_error=="");defer destroy_mesh(&loaded)
	testing.expect(t,len(loaded.vertices)==len(mesh.vertices) && len(loaded.indices)==len(mesh.indices))
	for vertex,i in loaded.vertices {testing.expect(t,vertex==mesh.vertices[i],"float bits, normals and colors survive exactly")}
	for index,i in loaded.indices {testing.expect(t,index==mesh.indices[i],"triangle order and winding survive exactly")}
	if len(loaded.vertices)>0 {loaded.vertices[0].color[0]=0;testing.expect(t,mesh.vertices[0].color[0]==12,"decoded arrays have independent ownership")}
	empty_bytes,empty_error:=encode_mesh({});testing.expect(t,empty_error=="");defer delete(empty_bytes)
	empty,empty_load_error:=decode_mesh(empty_bytes);testing.expect(t,empty_load_error=="" && len(empty.vertices)==0 && len(empty.indices)==0);destroy_mesh(&empty)
}

@(test)
mesh_binary_rejects_truncation_corruption_and_invalid_geometry :: proc(t: ^testing.T) {
	mesh:Mesh;defer destroy_mesh(&mesh)
	testing.expect(t,append_tube(&mesh,([][3]f32{{0,0,0},{1,2,3}}),0.2))
	bytes,error:=encode_mesh(mesh);testing.expect(t,error=="");defer delete(bytes)
	for cut in 0..<len(bytes) {
		loaded,load_error:=decode_mesh(bytes[:cut]);testing.expect(t,load_error!="" && len(loaded.vertices)==0 && len(loaded.indices)==0);destroy_mesh(&loaded)
	}
	changed:=make([]u8,len(bytes)+1);defer delete(changed);copy(changed,bytes)
	_,error=decode_mesh(changed);testing.expect(t,error!="","trailing bytes cannot hide a malformed stream")
	changed=changed[:len(bytes)]
	changed[4]=2;_,error=decode_mesh(changed);testing.expect(t,error!="","unknown versions fail closed");copy(changed,bytes)
	mesh_binary_put_u32(changed[8:12],1000001);_,error=decode_mesh(changed);testing.expect(t,error!="","oversized allocations are rejected before allocation");copy(changed,bytes)
	changed[MESH_BINARY_HEADER_BYTES]~=1;_,error=decode_mesh(changed);testing.expect(t,error!="","payload corruption is detected even if values remain finite");copy(changed,bytes)
	mesh_binary_put_u32(changed[MESH_BINARY_HEADER_BYTES:MESH_BINARY_HEADER_BYTES+4],0x7fc00000)
	mesh_binary_put_u64(changed[16:24],xxhash.XXH3_64(changed[MESH_BINARY_HEADER_BYTES:]))
	_,error=decode_mesh(changed);testing.expect(t,error!="","nonfinite vertices remain invalid with a recomputed checksum")
	mesh.vertices[0].position[0]=transmute(f32)u32(0x7f800000)
	_,error=encode_mesh(mesh);testing.expect(t,error!="","invalid source data cannot be written")
}
