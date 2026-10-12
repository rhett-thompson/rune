package ecs

import "core:math/linalg"
import "core:testing"

@(private)
rotation_test_vector :: proc(rotation, vector: [3]f32) -> [3]f32 {
	return compose_transform_3d(Transform{rotation=rotation,scale={1,1,1}},Transform{position=vector,scale={1,1,1}}).position
}

@(test)
rotation_composition_applies_parent_after_local_for_mixed_axes :: proc(t: ^testing.T) {
	for parent in ([4][3]f32{{90,0,0},{20,35,10},{-25,70,35},{30,120,-15}}) {
		for local in ([4][3]f32{{0,-90,0},{10,45,-20},{-40,20,15},{0,270,0}}) {
			combined := compose_rotation_3d(parent, local)
			for axis in ([3][3]f32{{1,0,0},{0,1,0},{0,0,1}}) {
				expected := rotation_test_vector(parent, rotation_test_vector(local, axis))
				testing.expect(t,linalg.length(rotation_test_vector(combined,axis)-expected)<0.0001,"mixed-axis composition retains the specified order")
			}
		}
	}
	testing.expect(t,compose_rotation_3d({0,90,0},{0,-90,0})==[3]f32{},"shared-axis cancellation retains exact zero")
	testing.expect(t,compose_rotation_3d({}, {10,400,15})==[3]f32{10,400,15},"identity retains the original Euler representation")
}

@(test)
rotation_relative_removes_nonzero_frames_and_allows_replacement :: proc(t: ^testing.T) {
	base := [3]f32{0,-90,0}
	old := [3]f32{20,35,10}
	world := compose_rotation_3d(old,base)
	for next in ([4][3]f32{{90,0,0},{-25,70,35},{30,120,-15},{20,35,10}}) {
		world = compose_rotation_3d(next,relative_rotation_3d(old,world))
		for axis in ([3][3]f32{{1,0,0},{0,1,0},{0,0,1}}) {
			expected := rotation_test_vector(next,rotation_test_vector(base,axis))
			testing.expect(t,linalg.length(rotation_test_vector(world,axis)-expected)<0.0001,"replacement removes the old world rotation before applying the new one")
		}
		old = next
	}
	testing.expect(t,relative_rotation_3d({20,35,10},{20,35,10})==[3]f32{},"equal orientations represented identically remove to exact identity")
}
