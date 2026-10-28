package main

import "core:fmt"
import "core:slice"
import "core:time"
import "rune:geometry"
import "rune:jobs"

// CPU extraction only: setup, result destruction, World installation, and GPU
// uploads are outside the measured interval. Every pair runs serial first.
main :: proc() {
	volume:=geometry.Volume{size={96,64,96},spacing=1,cells=make([]u8,96*64*96)}
	defer delete(volume.cells)
	geometry.fill_box(volume,{0,0,0},volume.size,1)
	for z in 0..<8 {for x in 0..<8 {
		geometry.fill_box(volume,{x*12+2,2,z*12+2},{x*12+10,60,z*12+10},0)
	}}
	colors:=[2][4]u8{{},{255,255,255,255}}
	pool:=jobs.create(3,64)
	assert(pool!=nil,"the benchmark requires three worker threads")
	defer jobs.destroy(pool)
	serial,parallel:[9]f64
	for pass in 0..<10 {
		start:=time.tick_now()
		a,a_ok:=geometry.surface_chunks(volume,colors[:],{16,16,16})
		serial_ms:=time.duration_milliseconds(time.tick_since(start))
		serial_chunks:=len(a)
		geometry.destroy_mesh_chunks(&a)
		start=time.tick_now()
		b,b_ok:=geometry.surface_chunks(volume,colors[:],{16,16,16},pool)
		parallel_ms:=time.duration_milliseconds(time.tick_since(start))
		parallel_chunks:=len(b)
		geometry.destroy_mesh_chunks(&b)
		assert(a_ok && b_ok && serial_chunks==144 && parallel_chunks==serial_chunks)
		if pass>0 {serial[pass-1]=serial_ms;parallel[pass-1]=parallel_ms}
	}
	slice.sort(serial[:]);slice.sort(parallel[:])
	fmt.printf("geometry extraction median, 144 chunks / 9 warmed pairs: serial %.3f ms, 3 workers + caller %.3f ms, %.2fx\n",
		serial[4],parallel[4],serial[4]/parallel[4])
}
