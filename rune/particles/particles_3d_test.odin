package particles

import "core:math"
import "core:testing"

burst_test_settings :: proc() -> Burst3D {
	return {lifetime={0.5,1},speed={2,4},spread=160,gravity={0,-6,0},start_size=0.2,end_size=0,start_color={128,238,255,255},end_color={28,103,150,0},seed=131}
}

@(test)
bursts_are_bounded_replayable_and_face_the_surface :: proc(t: ^testing.T) {
	pool:Pool3D(16)
	settings:=burst_test_settings()
	for axis in ([6][3]f32{{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}}) {
		clear_3d(&pool)
		testing.expect(t,emit_burst_3d(&pool,settings,30,{3,4,5},axis)==16 && pool.count==16,"capacity drops excess births without allocating")
		for p in pool.particles[:pool.count] {
			outward:=p.velocity[0]*axis[0]+p.velocity[1]*axis[1]+p.velocity[2]*axis[2]
			speed:=math.sqrt(p.velocity[0]*p.velocity[0]+p.velocity[1]*p.velocity[1]+p.velocity[2]*p.velocity[2])
			testing.expect(t,outward>0 && speed>=2 && speed<=4.00001,"sparks remain in the outward hemisphere with the specified speed")
		}
		before:=pool
		testing.expect(t,emit_burst_3d(&pool,settings,1,{9,9,9},axis)==0 && pool==before,"a saturated pool preserves existing particles")
		clear_3d(&pool); emit_burst_3d(&pool,settings,16,{3,4,5},axis)
		testing.expect(t,pool==before,"clearing reproduces the seeded burst")
	}
}

@(test)
burst_motion_fades_and_expiry_use_simulation_time :: proc(t: ^testing.T) {
	pool:Pool3D(4)
	settings:=burst_test_settings(); settings.lifetime={1,1}; settings.speed={2,2}; settings.spread=0
	emit_burst_3d(&pool,settings,1,{0,2,0},{1,0,0})
	before:=pool; update_3d(&pool,0); testing.expect(t,pool==before)
	update_3d(&pool,0.5)
	p:=pool.particles[0]
	testing.expect(t,p.position==[3]f32{1,1.25,0} && p.velocity==[3]f32{2,-3,0},"ballistic motion includes world gravity")
	size,color:=appearance_3d(p)
	testing.expect(t,abs(size-0.1)<0.00001 && color==[4]u8{78,170,202,127},"size and radiance fade over the lifetime")
	testing.expect(t,p.start_size==before.particles[0].start_size,"birth settings survive later emitter changes")
	update_3d(&pool,0.5); testing.expect(t,pool.count==0,"expired particles stop rendering")
	testing.expect(t,emit_burst_3d(&pool,settings,4,{},{0,1,0})==4,"expired capacity can be reused")
}

@(test)
invalid_bursts_and_timesteps_do_not_mutate_the_pool :: proc(t: ^testing.T) {
	pool:Pool3D(4); settings:=burst_test_settings()
	emit_burst_3d(&pool,settings,1,{},{1,0,0}); before:=pool
	testing.expect(t,emit_burst_3d(&pool,settings,1,{},{})==0 && pool==before)
	settings.lifetime[0]=0
	testing.expect(t,emit_burst_3d(&pool,settings,1,{},{1,0,0})==0 && pool==before)
	update_3d(&pool,-1); update_3d(&pool,transmute(f32)u32(0x7f800000))
	testing.expect(t,pool==before)
}
