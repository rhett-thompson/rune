package main

import "core:fmt"
import "core:math"
import "rune:ecs"

validate_slope_speed_case :: proc(r:^ecs.Component_Registry, angle, acceleration:f32, direction, up:[3]f32) {
	w := ecs.init()
	defer ecs.destroy(&w)
	size := [3]f32{50, 0.3, 50}
	if up[0] != 0 {size={0.3, 50, 50}}
	box(&w, r, {}, size, {0, 0, angle})
	e := player(&w, r, up*3)
	config := ecs.default_character_controller_3d()
	config.move_speed=3
	config.acceleration=acceleration
	config.braking=6
	config.step_height=0
	assert(ecs.set(&w, e, config))
	assert(ecs.character_controller_3d_move_on_plane(&w, e, {}, up))
	step(&w, 120)
	assert(state(&w, e).grounded, "settle before measuring slope movement")
	assert(ecs.character_controller_3d_move_on_plane(&w, e, direction, up))
	actual_speed_sum:f32
	for frame in 0..<180 {
		before := pose(&w, e).position
		step(&w)
		assert(state(&w, e).grounded, "remain grounded while traversing the ramp")
		if frame < 120 {continue}
		velocity := (pose(&w, e).position-before)*60
		actual_speed_sum+=ecs.character_length_3d(velocity)
		planar := velocity-up*ecs.character_dot_3d(velocity, up)
		length := ecs.character_length_3d(planar)
		assert(length > 0.1 && ecs.character_dot_3d(planar/length, direction)>0.999,
			"slope following must preserve the requested movement azimuth")
	}
	actual_speed := actual_speed_sum/60
	assert(math.abs(actual_speed-3)<0.025,
		fmt.tprintf("slope cruise must reach configured surface speed: angle %.5f, acceleration %.1f, direction %v, up %v, actual %.5f", angle, acceleration, direction, up, actual_speed))
	assert(math.abs(ecs.character_length_3d(state(&w, e).velocity)-3)<0.025,
		"grounded runtime velocity must retain the complete slope tangent")
	assert(ecs.character_controller_3d_move_on_plane(&w, e, {}, up))
	before_speed := ecs.character_length_3d(state(&w, e).velocity)
	step(&w)
	after_speed := ecs.character_length_3d(state(&w, e).velocity)
	assert(math.abs(before_speed-after_speed-0.1)<0.015,
		"slope braking must use configured deceleration without projection losses")
	step(&w, 60)
	assert(ecs.character_length_3d(state(&w, e).velocity)<0.001, "stop on the slope")
	rest_position := pose(&w, e).position
	step(&w, 120)
	assert(ecs.character_length_3d(pose(&w, e).position-rest_position)<0.0025,
		"braked character must hold its position on the slope")
}

validate_slope_landing_speed :: proc(r:^ecs.Component_Registry) {
	for direction in ([3][3]f32{{},{1,0,0},{-1,0,0}}) {
		w := ecs.init()
		box(&w, r, {}, {50,0.3,50}, {0,0,40})
		e := player(&w, r, {0,8,0})
		config := ecs.default_character_controller_3d()
		config.move_speed=3
		config.acceleration=2
		config.braking=6
		assert(ecs.set(&w, e, config))
		assert(ecs.character_controller_3d_move(&w, e, {direction[0],direction[2]}))
		landed := false
		fall_speed:f32
		for _ in 0..<180 {
			step(&w)
			s := state(&w, e)
			if s.grounded {
				landed=true
				assert(ecs.character_length_3d(s.velocity)<=3.025,
					"landing must discard falling speed before preserving slope speed")
				if direction==([3]f32{}) {
					assert(ecs.character_length_3d(s.velocity)<0.001,
						"landing with zero input must not convert the fall into slope movement")
				}
				break
			}
			fall_speed=max(fall_speed, -s.velocity[1])
		}
		assert(landed && fall_speed>10, "exercise landing after a substantial airborne fall")
		for _ in 0..<90 {
			before := pose(&w, e).position
			step(&w)
			assert(state(&w, e).grounded, "stay grounded after landing on the slope")
			assert(ecs.character_length_3d(state(&w, e).velocity)<=3.025,
				"ground movement after landing must not inherit falling speed")
			actual_speed := ecs.character_length_3d(pose(&w, e).position-before)*60
			if direction==([3]f32{}) {
				assert(actual_speed<0.01, "stationary landing must hold position")
			} else {
				assert(actual_speed<=3.1, "moving landing must not produce a ground speed surge")
			}
		}
		ecs.destroy(&w)
	}
}

validate_slope_speed_transition :: proc(r:^ecs.Component_Registry, angle:f32, direction:f32) {
	w := ecs.init()
	defer ecs.destroy(&w)
	box(&w, r, {-15,-0.5,0}, {30,1,20})
	// The inclined top meets the floor at X=0, with solid overlap below it.
	radians := angle*f32(math.PI/180)
	slope := math.tan(radians)
	box(&w, r, {10,10*slope-0.15/math.cos(radians),0}, {30,0.3,20}, {0,0,angle})
	start := [3]f32{-6,2,0}
	if direction<0 {start={10,10*slope+2,0}}
	e := player(&w, r, start)
	config := ecs.default_character_controller_3d()
	config.move_speed=3
	config.acceleration=2
	config.braking=6
	assert(ecs.set(&w, e, config))
	step(&w, 120)
	assert(state(&w, e).grounded, "settle before floor/ramp crossing")
	assert(ecs.character_controller_3d_move(&w, e, {direction,0}))
	measured_flat, measured_slope := false, false
	for frame in 0..<420 {
		before := pose(&w, e).position
		step(&w)
		s := state(&w, e)
		assert(s.grounded, "floor/ramp seam must retain ground contact")
		if frame<120 {continue}
		assert(math.abs(ecs.character_length_3d(s.velocity)-3)<0.025,
			"ground normal changes must preserve motor surface speed")
		after := pose(&w, e).position
		actual_speed := ecs.character_length_3d(after-before)*60
		// The rounded capsule changes its feet clearance at the seam. Measure
		// the continuous walking surfaces clear of that short contact transition.
		if before[0]<-1 && after[0]<-1 {
			measured_flat=true
			assert(math.abs(actual_speed-3)<0.05, "recover full floor speed after the slope")
		} else if before[0]>1 && after[0]>1 {
			measured_slope=true
			assert(math.abs(actual_speed-3)<0.05, "retain full slope speed after the floor")
		}
	}
	assert(measured_flat && measured_slope, "cross and measure both sides of the floor/ramp seam")
}

validate_slope_speed :: proc(r:^ecs.Component_Registry) {
	diagonal := f32(math.sqrt(0.5))
	directions := [][3]f32{{1,0,0},{-1,0,0},{0,0,1},{diagonal,0,diagonal},{-diagonal,0,diagonal}}
	for angle in ([2]f32{26.56505, 40}) {
		for acceleration in ([2]f32{8, 2}) {
			for direction in directions {
				validate_slope_speed_case(r, angle, acceleration, direction, {0,1,0})
			}
		}
	}
	// The same surface-speed and braking rules apply when local gravity is sideways.
	validate_slope_speed_case(r, 40, 2, {0,1,0}, {1,0,0})
	validate_slope_speed_case(r, 40, 2, {0,-1,0}, {1,0,0})
	validate_slope_speed_case(r, 40, 2, {0,diagonal,diagonal}, {1,0,0})
	validate_slope_landing_speed(r)
	for angle in ([2]f32{26.56505,40}) {
		validate_slope_speed_transition(r, angle, 1)
		validate_slope_speed_transition(r, angle, -1)
	}
	fmt.println("PASS slope cruise speed, azimuth, braking, landing, transitions, and arbitrary up")
}
