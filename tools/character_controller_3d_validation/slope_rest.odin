package main

import "core:fmt"
import "core:math"
import "rune:ecs"

validate_slope_rest :: proc(r:^ecs.Component_Registry) {
	// Include the navigation example's 1:2 grade and slopes facing across both
	// world axes. Ground contact must leave enough normal clearance that an
	// idle capsule does not need another sideways skin correction every tick.
	rotations := [][3]f32{
		{0, 0, 10},
		{0, 0, 26.56505},
		{26.56505, 0, 0},
		{0, 45, 26.56505},
		{0, 0, 40},
	}
	for rotation in rotations {
		w := ecs.init()
		box(&w, r, {0, 0, 0}, {20, 0.3, 20}, rotation)
		e := player(&w, r, {0, 3, 0})
		step(&w, 120)
		assert(state(&w, e).grounded, "settle on walkable slope")
		start := pose(&w, e).position
		for _ in 0..<240 {
			step(&w)
			assert(state(&w, e).grounded, "remain grounded while resting on slope")
			position := pose(&w, e).position
			dx, dz := position[0]-start[0], position[2]-start[2]
			assert(math.sqrt(dx*dx+dz*dz) <= 0.0025, "idle slope contact must not creep downhill")
		}
		ecs.destroy(&w)
	}
	fmt.println("PASS resting contact on walkable slopes")
}
