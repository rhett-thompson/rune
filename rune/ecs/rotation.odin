package ecs

import "core:math/linalg"

@(private)
rotations_share_axis_3d :: proc(first, second: [3]f32) -> bool {
	axes := 0
	for axis in 0..<3 {
		if first[axis] != 0 || second[axis] != 0 {axes += 1}
	}
	return axes <= 1
}

// Compose Euler-degree orientations in the same Z/Y/X convention as Transform.
// The local orientation applies first, then the parent orientation. Mixed axes
// compose through quaternions; equivalent Euler representations may differ.
compose_rotation_3d :: proc(parent, local: [3]f32) -> [3]f32 {
	if parent == ([3]f32{}) {return local}
	if local == ([3]f32{}) {return parent}
	if rotations_share_axis_3d(parent, local) {return parent + local}
	p, l := parent * Radians_Per_Degree, local * Radians_Per_Degree
	parent_orientation := linalg.quaternion_from_pitch_yaw_roll(p[0], p[1], p[2])
	local_orientation := linalg.quaternion_from_pitch_yaw_roll(l[0], l[1], l[2])
	z, y, x := linalg.euler_angles_zyx_from_quaternion(parent_orientation * local_orientation)
	return [3]f32{x, y, z} / Radians_Per_Degree
}

// Remove a parent orientation from a world orientation, both in Euler degrees.
// compose_rotation_3d(parent, result) recovers the world orientation; equivalent
// Euler representations may differ. Mixed axes use inverse quaternion order.
relative_rotation_3d :: proc(parent, world: [3]f32) -> [3]f32 {
	if parent == ([3]f32{}) {return world}
	if parent == world {return {}}
	if rotations_share_axis_3d(parent, world) {return world - parent}
	p, w := parent * Radians_Per_Degree, world * Radians_Per_Degree
	parent_orientation := linalg.quaternion_from_pitch_yaw_roll(p[0], p[1], p[2])
	world_orientation := linalg.quaternion_from_pitch_yaw_roll(w[0], w[1], w[2])
	z, y, x := linalg.euler_angles_zyx_from_quaternion(linalg.quaternion_inverse(parent_orientation) * world_orientation)
	return [3]f32{x, y, z} / Radians_Per_Degree
}
