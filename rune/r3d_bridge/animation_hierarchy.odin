package r3d_bridge

import r3d "r3d:r3d"
import rl "vendor:raylib"

// Assimp mesh-bone indices need not put parents before children. Cache a
// validated evaluation order without renumbering skin weights or clip tracks.
animation_pose_order :: proc(skeleton:r3d.Skeleton)->([]i32,bool) {
	count:=int(skeleton.boneCount)
	if count<=0 || skeleton.bones==nil {return nil,false}
	order:=make([]i32,count)
	visited:=make([]u8,count); defer delete(visited)
	chain:=make([]i32,count); defer delete(chain)
	written:=0
	for start in 0..<count {
		bone,depth:=i32(start),0
		for bone != -1 {
			if bone<0 || int(bone)>=count || visited[bone]==1 {delete(order);return nil,false}
			if visited[bone]==2 {break}
			visited[bone]=1;chain[depth]=bone;depth+=1
			bone=skeleton.bones[bone].parent
		}
		for depth>0 {
			depth-=1;bone=chain[depth]
			visited[bone]=2;order[written]=bone;written+=1
		}
	}
	return order,true
}

compute_ordered_animation_model_pose :: proc(player:^r3d.AnimationPlayer,order:[]i32) {
	root:=transmute(rl.Matrix)player.skeleton.rootBind
	for bone in order {
		parent:=player.skeleton.bones[bone].parent
		parent_pose:=player.modelPose[parent] if parent>=0 else root
		player.modelPose[bone]=parent_pose*player.localPose[bone]
	}
}
