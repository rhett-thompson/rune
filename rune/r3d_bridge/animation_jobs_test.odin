package r3d_bridge

import "core:mem"
import "core:sync"
import "core:testing"
import "core:time"
import "rune:jobs"
import r3d "r3d:r3d"
import rl "vendor:raylib"

Animation_Test_Gate :: struct {started,release:sync.Sema}
animation_test_gate :: proc(data:rawptr) {g:=(^Animation_Test_Gate)(data);sync.sema_post(&g.started);sync.sema_wait(&g.release)}
animation_test_increment :: proc(data:rawptr) {(^int)(data)^+=1}
Animation_Test_Worker :: struct {work:[]Animation_Pose_Work,thread_id:int}
animation_test_background :: proc(data:rawptr) {
	job:=(^Animation_Test_Worker)(data);job.thread_id=sync.current_thread_id()
	evaluate_animation_poses(job.work,nil)
}

@(test)
animation_pose_jobs_match_serial_and_run_without_caller_allocations :: proc(t:^testing.T) {
	Actors::64;Bones::32
	bones:[Bones]r3d.BoneInfo
	bind,inverse:[Bones]rl.Matrix
	for &bone,index in bones {bone.parent=i32(index)-1;bind[index]=rl.Matrix(1);inverse[index]=rl.Matrix(1)}
	times:=[2]f32{0,1}
	positions:[Bones][2]rl.Vector3
	rotations:[Bones][2]rl.Quaternion
	scales:[Bones][2]rl.Vector3
	channels:[Bones]r3d.AnimationChannel
	for &channel,index in channels {
		positions[index]={{f32(index)*0.01,0.1,0},{0.5,f32(index)*0.02,0.25}}
		rotations[index]={rl.Quaternion(1),rl.QuaternionFromEuler(0.1,0.3,0.2)}
		scales[index]={{1,1,1},{1.02,1.01,1.03}}
		channel.boneIndex=i32(index)
		channel.translation={times=raw_data(times[:]),values=([^]f32)(raw_data(positions[index][:])),count=2}
		channel.rotation={times=raw_data(times[:]),values=([^]f32)(raw_data(rotations[index][:])),count=2}
		channel.scale={times=raw_data(times[:]),values=([^]f32)(raw_data(scales[index][:])),count=2}
	}
	clip:=r3d.Animation{channels=raw_data(channels[:]),channelCount=Bones,ticksPerSecond=1,duration=1,boneCount=Bones}
	skeleton:=r3d.Skeleton{bones=raw_data(bones[:]),boneCount=Bones,localBind=raw_data(bind[:]),modelBind=raw_data(bind[:]),invBind=raw_data(inverse[:]),rootBind=transmute([16]f32)rl.Matrix(1)}
	states:[Actors]r3d.AnimationState
	local,model:[Actors][Bones]rl.Matrix
	blend:[Bones]rl.Matrix
	for &pose,index in blend {pose=rl.MatrixTranslate(f32(index)*0.02,0,0)*rl.MatrixRotateY(0.3)}
	work:[Actors]Animation_Pose_Work
	for &item,index in work {
		states[index]={currentTime=f32(index+1)/f32(Actors+1),speed=1,play=true,loop=true}
		item.player={animLib={animations=&clip,count=1},skeleton=skeleton,states=&states[index],activeAnimIndex=0,
			localPose=raw_data(local[index][:]),modelPose=raw_data(model[index][:])}
		if index%2!=0 {item.blend_pose=blend[:];item.blend_weight=0.35}
	}
	pool:=jobs.create(3,1);if !testing.expect(t,pool!=nil) {return};defer jobs.destroy(pool)
	full_pool:=jobs.create(1,1);if !testing.expect(t,full_pool!=nil) {return};defer jobs.destroy(full_pool)
	tracker:mem.Tracking_Allocator;mem.tracking_allocator_init(&tracker,context.allocator);defer mem.tracking_allocator_destroy(&tracker)
	context.allocator=mem.tracking_allocator(&tracker)
	testing.expect(t,!evaluate_animation_poses(work[:],nil))
	expected_local,expected_model:=local,model
	expected_states:=states
	local={};model={}
	testing.expect(t,evaluate_animation_poses(work[:],pool),"the synthetic workload crosses the production 2048-bone dispatch threshold")
	testing.expect(t,local==expected_local && model==expected_model && states==expected_states,"pooled local/model poses match serial without advancing native states")
	// Force native evaluation to execute on an actual worker, independently of
	// how many indices the helping owner wins in an ordinary parallel batch.
	local={};model={}
	background:=Animation_Test_Worker{work=work[:]};background_group:jobs.Group
	assert(jobs.submit(pool,&background_group,animation_test_background,&background));jobs.wait(&background_group)
	testing.expect(t,background.thread_id!=sync.current_thread_id() && local==expected_local && model==expected_model,
		"the same native CPU pose evaluator runs safely on a different thread")
	gate:Animation_Test_Gate;gate_group,fill_group:jobs.Group;fill_count:int
	assert(jobs.submit(full_pool,&gate_group,animation_test_gate,&gate))
	if !testing.expect(t,sync.sema_wait_with_timeout(&gate.started,2*time.Second)) {sync.sema_post(&gate.release);jobs.wait(&gate_group);return}
	assert(jobs.submit(full_pool,&fill_group,animation_test_increment,&fill_count))
	local={};model={}
	testing.expect(t,evaluate_animation_poses(work[:],full_pool))
	testing.expect(t,local==expected_local && model==expected_model,"a full queue keeps synchronous completion through caller help")
	sync.sema_post(&gate.release);jobs.wait(&gate_group);jobs.wait(&fill_group)
	testing.expect(t,fill_count==1)
	testing.expect(t,tracker.total_allocation_count==0 && len(tracker.allocation_map)==0,"CPU evaluation makes no caller persistent allocation calls")
}
