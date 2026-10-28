package r3d_bridge

import "rune:jobs"
import "rune:ecs"
import r3d "r3d:r3d"
import rl "vendor:raylib"

// Borrowed, exclusively writable player buffers and read-only blend source.
// Skeleton/library storage stays immutable through evaluate_animation_poses.
// No player creation, destruction, timeline callbacks, allocation, or GL here.
Animation_Pose_Work :: struct {
	player: r3d.AnimationPlayer,
	blend_pose: []rl.Matrix,
	blend_weight: f32,
}

Animation_Pose_Batch :: struct {work: []Animation_Pose_Work}

Animation_Stats :: struct {
	players_evaluated, bones_evaluated, job_batches: int,
	// Owner elapsed time, including the CPU batch barrier; not summed worker time.
	pose_cpu_ms, upload_cpu_ms: f64,
}

// Conservative cutoff from the Windows/Linux keyed-hierarchy benchmark.
Animation_Parallel_Min_Bones :: 2048

evaluate_animation_pose :: proc(work: ^Animation_Pose_Work) {
	r3d.ComputeAnimationLocalPose(&work.player)
	for pose, bone in work.blend_pose {
		work.player.localPose[bone]=blend_local_pose(pose,work.player.localPose[bone],work.blend_weight)
	}
	r3d.ComputeAnimationModelPose(&work.player)
}

animation_pose_job :: proc(index:int,data:rawptr) {
	batch:=(^Animation_Pose_Batch)(data)
	evaluate_animation_pose(&batch.work[index])
}

// Synchronous batch: completion precedes owner-side upload, cleanup and cache
// publication. Small/no-pool workloads avoid dispatch and runner setup entirely.
// A full pool lets the caller do the work; jobs.parallel_for handles nesting.
evaluate_animation_poses :: proc(work:[]Animation_Pose_Work,pool:^jobs.Pool) -> bool {
	bones:=0
	for item in work {bones+=int(item.player.skeleton.boneCount)}
	parallel:=pool!=nil && len(work)>1 && bones>=Animation_Parallel_Min_Bones
	if parallel {
		batch:=Animation_Pose_Batch{work}
		jobs.parallel_for(pool,len(work),animation_pose_job,&batch)
	} else {
		for &item in work {evaluate_animation_pose(&item)}
	}
	return parallel
}

@(private)
Animation_Pose_Commit :: struct {
	entity: ecs.Entity,
	cached: Model_Player,
	finish_blend: bool,
}
