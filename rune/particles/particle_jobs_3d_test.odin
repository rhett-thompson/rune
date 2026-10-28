package particles

import "core:slice"
import "core:mem"
import "core:testing"
import "rune:jobs"

particle_job_test_3d :: proc(index: int) -> Particle3D {
	return {position={f32(index),3,-2}, velocity={1,f32(index%7),-4}, gravity={0,-9,1},
		age=f32(index%9)*0.01, lifetime=0.07+f32(index%23)*0.031,
		start_size=f32(index+1), end_size=0.25, start_color={u8(index%251),7,113,255}, end_color={3,11,17,0}}
}

@(test)
particle_3d_worker_ranges_preserve_exact_live_prefix_through_expiry :: proc(t: ^testing.T) {
	pool := jobs.create(3, 1); if !testing.expect(t, pool != nil) {return}; defer jobs.destroy(pool)
	for count in ([7]int{0,1,1023,Particle_Parallel_Min_Count_3D-1,Particle_Parallel_Min_Count_3D,Particle_Parallel_Min_Count_3D+1,2*Particle_Parallel_Min_Count_3D+547}) {
		serial := make([]Particle3D, count); defer delete(serial)
		parallel := make([]Particle3D, count); defer delete(parallel)
		for &particle, index in serial {particle = particle_job_test_3d(index)}
		copy(parallel, serial)
		serial_count, parallel_count := count, count
		for dt in ([8]f32{0,-1,transmute(f32)u32(0x7fc00000),transmute(f32)u32(0x7f800000),0.016,0.043,0.2,10}) {
			serial_count = update_3d_slice(serial[:serial_count], dt)
			parallel_count = update_3d_slice(parallel[:parallel_count], dt, pool)
			testing.expect(t, serial_count == parallel_count && slice.equal(serial[:serial_count], parallel[:parallel_count]),
				"range integration plus owner compaction preserves every field and legacy swap/pop order")
		}
		testing.expect(t, serial_count == 0, "all expired particles are reclaimed")
	}
	// The fixed-capacity wrapper keeps RNG ownership and remains source compatible.
	serial := new(Pool3D(Particle_Parallel_Min_Count_3D+2048)); defer mem.free(serial)
	parallel := new(Pool3D(Particle_Parallel_Min_Count_3D+2048)); defer mem.free(parallel)
	settings := burst_test_settings()
	emit_burst_3d(serial, settings, Particle_Parallel_Min_Count_3D+1024, {2,3,4}, {0,1,0})
	copy(parallel.particles[:], serial.particles[:]); parallel.count = serial.count; parallel.random = serial.random
	for dt in ([3]f32{0.016,0.2,2}) {
		update_3d(serial, dt); update_3d(parallel, dt, pool)
		testing.expect(t, serial.count == parallel.count && serial.random == parallel.random &&
			slice.equal(serial.particles[:serial.count], parallel.particles[:parallel.count]), "fixed pool live prefix and random stream match exactly")
	}
}
