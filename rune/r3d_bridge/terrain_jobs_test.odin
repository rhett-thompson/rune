package r3d_bridge

import "core:testing"
import "rune:jobs"
import "rune:terrain"

@(test)
terrain_cpu_jobs_preserve_partial_chunk_order_and_owned_buffers :: proc(t: ^testing.T) {
	pool := jobs.create(3,1)
	if !testing.expect(t,pool!=nil) {return}
	defer jobs.destroy(pool)
	d := terrain.default_description();d.resolution={34,27};d.size={33,26};d.chunk_cells=8
	heights := make([]f32,34*27);defer delete(heights)
	for &height,index in heights {height=f32((index*17)%29)*0.03}
	data := terrain.Data{description=d,heights=heights}
	columns,rows := 5,4
	for offset:=0;offset<columns*rows;offset+=Terrain_Chunk_Job_Wave {
		count:=min(Terrain_Chunk_Job_Wave,columns*rows-offset)
		work:=Terrain_Chunk_Work{data=data,columns=columns,offset=offset}
		jobs.parallel_for(pool,count,prepare_terrain_chunk_job,&work)
		for index in 0..<count {
			i:=offset+index;x,z:=(i%columns)*8,(i/columns)*8
			expected:=build_terrain_chunk_cpu(data,x,z,min(8,33-x),min(8,26-z))
			actual:=&work.chunks[index]
			testing.expect(t,len(actual.vertices)==len(expected.vertices) && len(actual.indices)==len(expected.indices))
			for vertex,j in expected.vertices {testing.expect(t,actual.vertices[j]==vertex,"packed positions, normals and UVs match the serial chunk")}
			for value,j in expected.indices {testing.expect(t,actual.indices[j]==value,"parallel chunks retain exact cell topology")}
			destroy_terrain_chunk_cpu(&expected)
			destroy_terrain_chunk_cpu(actual)
		}
	}
}

@(test)
terrain_detail_jobs_preserve_scatter_order_and_allocator_ownership :: proc(t: ^testing.T) {
	pool:=jobs.create(3,1)
	if !testing.expect(t,pool!=nil) {return}
	defer jobs.destroy(pool)
	d:=terrain.default_description();d.resolution={17,17};d.size={16,16}
	heights:=make([]f32,17*17);defer delete(heights)
	for &height,index in heights {height=f32((index*7)%13)*0.03}
	details:[3]terrain.Detail
	for &detail,index in details {detail=terrain.default_detail();detail.count=5000;detail.seed=index+10;detail.slope={0,90}}
	d.details=details[:]
	data:=terrain.Data{description=d,heights=heights}
	batches:[3]Terrain_Detail_Batch
	work:=Terrain_Detail_Work{data=data,batches=batches[:]}
	jobs.parallel_for(pool,len(batches),scatter_terrain_detail_job,&work)
	for &batch,index in batches {
		expected:=terrain.scatter_details(data,details[index])
		testing.expect(t,len(batch.instances)==len(expected))
		for instance,j in expected {testing.expect(t,batch.instances[j]==instance,"candidate rejection and random streams retain authored ordering")}
		delete(expected)
		release_detail_batch(&batch)
	}
}
