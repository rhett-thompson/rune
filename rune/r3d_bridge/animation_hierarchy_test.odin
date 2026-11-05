package r3d_bridge

import "core:testing"
import r3d "r3d:r3d"
import rl "vendor:raylib"

@(test)
animation_hierarchy_evaluates_child_first_bones_on_the_first_pose :: proc(t:^testing.T) {
	bones:=[3]r3d.BoneInfo{{parent=2},{parent=-1},{parent=1}}
	local:=[3]rl.Matrix{rl.MatrixTranslate(0,1,0),rl.MatrixRotateY(0.8),rl.MatrixTranslate(2,0,0)}
	model:[3]rl.Matrix
	root:=rl.MatrixTranslate(0,3,0)
	skeleton:=r3d.Skeleton{bones=raw_data(bones[:]),boneCount=3,rootBind=transmute([16]f32)root}
	order,ok:=animation_pose_order(skeleton);defer delete(order)
	if !testing.expect(t,ok && len(order)==3) {return}
	player:=r3d.AnimationPlayer{skeleton=skeleton,localPose=raw_data(local[:]),modelPose=raw_data(model[:])}
	compute_ordered_animation_model_pose(&player,order)
	testing.expect(t,model[1]==root*local[1] && model[2]==root*local[1]*local[2] && model[0]==root*local[1]*local[2]*local[0],"every parent uses this pose's matrix, independent of imported bone indices")
	// Repeated draws must not gradually converge from stale parent matrices.
	first:=model;compute_ordered_animation_model_pose(&player,order)
	testing.expect(t,model==first,"a frozen pose is correct immediately and stable on repeated evaluation")
	bones[1].parent=0
	invalid,cyclic:=animation_pose_order(skeleton);defer delete(invalid)
	testing.expect(t,!cyclic,"cyclic rigs are rejected before worker evaluation")
	bones[1].parent=4
	invalid_parent,valid:=animation_pose_order(skeleton);defer delete(invalid_parent)
	testing.expect(t,!valid,"out-of-range parents are rejected")
}

@(test)
animation_hierarchy_matches_native_for_parent_first_bones :: proc(t:^testing.T) {
	bones:=[3]r3d.BoneInfo{{parent=-1},{parent=0},{parent=1}}
	local:=[3]rl.Matrix{rl.MatrixRotateY(0.6),rl.MatrixTranslate(1,2,0),rl.MatrixRotateX(0.3)}
	model:[3]rl.Matrix
	skeleton:=r3d.Skeleton{bones=raw_data(bones[:]),boneCount=3,rootBind=transmute([16]f32)rl.MatrixTranslate(4,0,0)}
	player:=r3d.AnimationPlayer{skeleton=skeleton,localPose=raw_data(local[:]),modelPose=raw_data(model[:]),activeAnimIndex=-1}
	// A valid native animation index selects native hierarchy accumulation.
	clip:r3d.Animation;player.animLib={animations=&clip,count=1};player.activeAnimIndex=0
	r3d.ComputeAnimationModelPose(&player)
	expected:=model;model={}
	order,ok:=animation_pose_order(skeleton);defer delete(order);assert(ok)
	compute_ordered_animation_model_pose(&player,order)
	for value,index in model {
		close:=true
		for row in 0..<4 {for column in 0..<4 {close=close && abs(value[row,column]-expected[index][row,column])<0.000001}}
		testing.expect(t,close,"the ordered path preserves native multiplication and root-bind conventions")
	}
}
