package main

import "core:fmt"
import "rune:navigation"

require :: proc(condition: bool, message: string) {
	if !condition { panic(message) }
}

main :: proc() {
	grid, ok := navigation.init_grid(12, 8, 1)
	require(ok, "grid creation failed")
	defer navigation.destroy_grid(&grid)
	for y: i32 = 0; y < 7; y += 1 { navigation.set_blocked(&grid, {5, y}) }

	a_star, found_a := navigation.find_path(&grid, {1, 1}, {10, 1}, .A_Star)
	theta, found_theta := navigation.find_path(&grid, {1, 1}, {10, 1}, .Theta_Star)
	defer delete(a_star)
	defer delete(theta)
	require(found_a && found_theta, "both algorithms should route through the opening")
	require(len(theta) < len(a_star), "Theta* should remove unnecessary grid waypoints")
	for i in 1..<len(theta) {
		require(navigation.line_of_sight(&grid, theta[i - 1], theta[i]), "Theta* emitted an obstructed segment")
	}

	navigation.set_blocked(&grid, {5, 7})
	_, unreachable := navigation.find_path(&grid, {1, 1}, {10, 1}, .A_Star)
	require(!unreachable, "sealed wall should be unreachable")
	fmt.println("navigation validation passed")
}
