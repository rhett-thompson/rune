package r3d_bridge

import "core:math"
import rl "vendor:raylib"

// Skeletal local poses are TRS transforms. Rotation uses shortest-path slerp;
// translation and scale interpolate linearly. Exact endpoints stay untouched.
blend_local_pose :: proc(a,b: rl.Matrix, weight: f32) -> rl.Matrix {
	if weight <= 0 {return a}
	if weight >= 1 {return b}
	ta,sa,qa := decompose_pose(a)
	tb,sb,qb := decompose_pose(b)
	t,s := ta+(tb-ta)*weight,sa+(sb-sa)*weight
	q := rl.QuaternionSlerp(qa,qb,weight)
	return rl.MatrixTranslate(t.x,t.y,t.z)*rl.QuaternionToMatrix(q)*rl.MatrixScale(s.x,s.y,s.z)
}

@(private)
decompose_pose :: proc(m: rl.Matrix) -> (rl.Vector3,rl.Vector3,rl.Quaternion) {
	scale: rl.Vector3
	rotation := m
	for axis in 0..<3 {
		scale[axis] = math.sqrt(m[0,axis]*m[0,axis]+m[1,axis]*m[1,axis]+m[2,axis]*m[2,axis])
	}
	if rl.MatrixDeterminant(m)<0 {scale.x = -scale.x}
	for axis in 0..<3 {
		if math.abs(scale[axis])>0.000001 {
			for row in 0..<3 {rotation[row,axis] /= scale[axis]}
		}
	}
	return {m[0,3],m[1,3],m[2,3]},scale,rl.QuaternionFromMatrix(rotation)
}
