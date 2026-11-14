package main

import "core:fmt"
import "core:math"
import "core:slice"
import "core:time"
import "rune:assets"
import "rune:ecs"
import "rune:jobs"
import bridge "rune:r3d_bridge"
import r3d "r3d:r3d"
import rl "vendor:raylib"

benchmark_terrain_regions :: proc() {
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(320,180,"Terrain region benchmark")
	defer rl.CloseWindow()
	assert(rl.IsWindowReady())
	pool := jobs.create(3,8)
	assert(pool != nil)
	defer jobs.destroy(pool)
	ctx,ready := bridge.init(".",320,180,worker_pool=pool)
	assert(ready)
	defer bridge.shutdown(&ctx)
	r3d.SetAntiAliasingMode(.NONE)
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	fmt.println("Five alternating radius-four edits per size, one metre/sample, 64-cell chunks, three render workers")
	for samples in ([3]int{129,257,513}) {benchmark_terrain_size(&ctx,&registry,samples)}
}

benchmark_terrain_size :: proc(ctx: ^bridge.Context, registry: ^ecs.Component_Registry, samples: int) {
	Asset :: "build/terrain-region-benchmark.terrain.json"
	Heightmap :: "build/terrain-region-benchmark.r16"
	Center :: 40
	Radius :: 4
	Width :: 2*Radius+1
	Edits :: 5
	bytes := make([]u8,samples*samples*2)
	defer delete(bytes)
	assert(write_fixture(Heightmap,bytes)==nil)
	description := fmt.tprintf(`{{"heightmap":"%s","resolution":[%d,%d],"size":[%d,%d],"chunk_cells":64}}`,
		Heightmap,samples,samples,samples-1,samples-1)
	assert(write_fixture(Asset,description)==nil)
	manager := assets.init(".")
	defer assets.shutdown(&manager)
	w := ecs.init()
	defer ecs.destroy(&w)
	e := add_region_terrain(&w,registry,Asset)
	ecs.sync_terrains(&w,&manager)
	bridge.prepare_terrains(ctx,&w,&manager)
	chunk_count := ((samples-1)/64)*((samples-1)/64)
	assert(len(ctx.terrains[e].chunks)==chunk_count)
	previous := make([]r3d.Mesh,chunk_count)
	defer delete(previous)

	preview_ms, bridge_ms, prep_ms, upload_ms, commit_ms: [Edits]f64
	last_height: f32
	for edit in 0..<Edits {
		height: f32 = 16 if edit%2 == 0 else 0
		patch: [Width*Width]f32
		for z in -Radius..=Radius {
			for x in -Radius..=Radius {
				if x*x+z*z <= Radius*Radius {patch[(z+Radius)*Width+x+Radius] = height}
			}
		}
		copy(previous,ctx.terrains[e].chunks[:])
		ctx.frame_stats = {}
		started := time.tick_now()
		assert(ecs.update_terrain_region(&w,e,Center-Radius,Center-Radius,Center+Radius+1,Center+Radius+1,patch[:]))
		preview_ms[edit] = time.duration_milliseconds(time.tick_since(started))
		started = time.tick_now()
		bridge.prepare_terrains(ctx,&w,&manager)
		bridge_ms[edit] = time.duration_milliseconds(time.tick_since(started))
		assert(ctx.frame_stats.terrain_chunks_built==1,"one chunk is rebuilt at every resolution")
		for mesh,index in ctx.terrains[e].chunks {
			assert((mesh.vertexOffset!=previous[index].vertexOffset)==(index==0))
			assert((mesh.indexOffset!=previous[index].indexOffset)==(index==0))
		}
		prep_ms[edit] = ctx.frame_stats.terrain_prepare_cpu_ms
		upload_ms[edit] = ctx.frame_stats.terrain_upload_cpu_ms
		assert(math.abs(raycast_region_height(&w,e,Center,Center)-last_height)<0.001)
		started = time.tick_now()
		assert(ecs.commit_terrain_region(&w,e))
		commit_ms[edit] = time.duration_milliseconds(time.tick_since(started))
		assert(math.abs(raycast_region_height(&w,e,Center,Center)-height)<0.001)
		last_height = height
	}
	for timings in ([5][]f64{preview_ms[:],bridge_ms[:],prep_ms[:],upload_ms[:],commit_ms[:]}) {slice.sort(timings)}
	Median :: Edits/2
	fmt.printf("%dx%d: 1/%d chunks rebuilt. CPU medians (ms): patch %.3f, bridge %.3f (geometry %.3f, upload %.3f), collision commit %.3f\n",
		samples,samples,chunk_count,preview_ms[Median],bridge_ms[Median],prep_ms[Median],upload_ms[Median],commit_ms[Median])
}
