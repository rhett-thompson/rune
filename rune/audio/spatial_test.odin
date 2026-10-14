package audio

import "core:testing"
import "rune:ecs"

@(test)
spatial_audio_follows_emitter_and_listener_hierarchies :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r)
	testing.expect(t,ecs.register_builtin_components(&r))
	listener_parent:=ecs.create_entity(&w)
	testing.expect(t,ecs.add(&w,&r,listener_parent,ecs.Transform{position={10,0,10},rotation={0,90,0},scale={2,3,4}}))
	gap:=ecs.create_entity(&w); testing.expect(t,ecs.set_parent(&w,gap,listener_parent))
	listener:=ecs.create_entity(&w); testing.expect(t,ecs.set_parent(&w,listener,gap))
	testing.expect(t,ecs.add(&w,&r,listener,ecs.Transform{position={1,1,0},scale={1,1,1}}))
	emitter_parent:=ecs.create_entity(&w)
	testing.expect(t,ecs.add(&w,&r,emitter_parent,ecs.Transform{position={20,0,0},rotation={0,90,0},scale={1,1,1}}))
	emitter:=ecs.create_entity(&w); testing.expect(t,ecs.set_parent(&w,emitter,emitter_parent))
	testing.expect(t,ecs.add(&w,&r,emitter,ecs.Transform{position={-8,3,-6},scale={1,1,1}}))
	player:=ecs.AudioPlayer{spatial=true,min_distance=2,max_distance=6}
	// Composed positions are (10,3,8) and (14,3,8), four world units apart.
	gain,pan:=spatial_factors(&w,emitter,player,listener,true)
	testing.expect(t,abs(gain-0.5)<0.001 && abs(pan)<0.001,"the parent's rotated right axis keeps a world-X source centered")
	pose,_:=ecs.get_transform(&w,emitter_parent); pose.position.x+=2
	testing.expect(t,ecs.set_transform(&w,emitter_parent,pose))
	gain,pan=spatial_factors(&w,emitter,player,listener,true)
	testing.expect(t,abs(gain)<0.001 && abs(pan)<0.001,"moving the emitter parent changes attenuation")
	pose,_=ecs.get_transform(&w,listener_parent); pose.position.x+=2
	testing.expect(t,ecs.set_transform(&w,listener_parent,pose))
	gain,pan=spatial_factors(&w,emitter,player,listener,true)
	testing.expect(t,abs(gain-0.5)<0.001 && abs(pan)<0.001,"moving the listener parent updates its reference point")
	pose.rotation={0,180,0}
	testing.expect(t,ecs.set_transform(&w,listener_parent,pose))
	emitter_pose,_:=ecs.get_transform(&w,emitter)
	emitter_pose.position={-10,3,-6}
	testing.expect(t,ecs.set_transform(&w,emitter,emitter_pose))
	// New composed positions are (10,3,10) and (16,3,10): source is to the listener's left.
	gain,pan=spatial_factors(&w,emitter,player,listener,true)
	testing.expect(t,abs(pan+1)<0.001,"parent rotation changes the standalone listener's stereo frame")
	player.spatial=false
	gain,pan=spatial_factors(&w,emitter,player,listener,true)
	testing.expect(t,gain==1 && pan==0,"nonspatial audio ignores hierarchy")
	player.spatial=true
	gain,pan=spatial_factors(&w,emitter,player,listener,false)
	testing.expect(t,gain==1 && pan==0,"a missing listener retains neutral settings")
}

@(test)
spatial_audio_pan_follows_camera_target_and_up :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r)
	testing.expect(t,ecs.register_builtin_components(&r))
	parent:=ecs.create_entity(&w)
	testing.expect(t,ecs.add(&w,&r,parent,ecs.Transform{position={10,2,5},rotation={0,90,0},scale={2,3,4}}))
	listener:=ecs.create_entity(&w); testing.expect(t,ecs.set_parent(&w,listener,parent))
	testing.expect(t,ecs.add(&w,&r,listener,ecs.Transform{position={1,1,0},scale={1,1,1}}))
	// The camera view is explicit: composed position (10,5,3), looking toward -Z.
	camera:=ecs.Camera3D{target={10,5,2},up={0,1,0},fovy=60,active=true}
	testing.expect(t,ecs.add(&w,&r,listener,camera))
	emitter:=ecs.create_entity(&w)
	testing.expect(t,ecs.add(&w,&r,emitter,ecs.Transform{position={14,5,3},scale={1,1,1}}))
	player:=ecs.AudioPlayer{spatial=true,min_distance=2,max_distance=6}
	gain,pan:=spatial_factors(&w,emitter,player,listener,true)
	testing.expect(t,abs(gain-0.5)<0.001 && abs(pan-1)<0.001,"screen-right is the right channel even when the camera parent is rotated")
	camera.target={10,5,4}; testing.expect(t,ecs.set_camera_3d(&w,listener,camera))
	gain,pan=spatial_factors(&w,emitter,player,listener,true)
	testing.expect(t,abs(gain-0.5)<0.001 && abs(pan+1)<0.001,"turning around swaps left and right without changing distance gain")
	camera.target={11,5,3}; testing.expect(t,ecs.set_camera_3d(&w,listener,camera))
	_,pan=spatial_factors(&w,emitter,player,listener,true)
	testing.expect(t,abs(pan)<0.001,"a source directly ahead is centered")
	camera.target={9,5,3}; testing.expect(t,ecs.set_camera_3d(&w,listener,camera))
	_,pan=spatial_factors(&w,emitter,player,listener,true)
	testing.expect(t,abs(pan)<0.001,"a source directly behind is centered")
	camera.target={10,5,2}; camera.up={1,0,0}
	testing.expect(t,ecs.set_camera_3d(&w,listener,camera))
	pose,_:=ecs.get_transform(&w,emitter); pose.position={10,1,3}
	testing.expect(t,ecs.set_transform(&w,emitter,pose))
	_,pan=spatial_factors(&w,emitter,player,listener,true)
	testing.expect(t,abs(pan-1)<0.001,"camera roll/up determines stereo right")
	camera.target={10,5,3}; testing.expect(t,ecs.set_camera_3d(&w,listener,camera))
	pose.position={10,5,-1}; testing.expect(t,ecs.set_transform(&w,emitter,pose))
	_,pan=spatial_factors(&w,emitter,player,listener,true)
	testing.expect(t,abs(pan-1)<0.001,"a degenerate camera view falls back to composed listener rotation")
}

@(test)
spatial_audio_distance_falloff_and_centered_fallbacks :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r)
	testing.expect(t,ecs.register_builtin_components(&r))
	listener:=ecs.create_entity(&w)
	testing.expect(t,ecs.add(&w,&r,listener,ecs.default_transform()))
	emitter:=ecs.create_entity(&w)
	testing.expect(t,ecs.add(&w,&r,emitter,ecs.default_transform()))
	player:=ecs.AudioPlayer{spatial=true,min_distance=2,max_distance=10}
	for sample in ([]struct{position:[3]f32,gain,pan:f32}{
		{{0,0,0},1,0},
		{{1,0,0},1,1},
		{{2,0,0},1,1},
		{{-6,0,0},0.5,-1},
		{{0,6,0},0.5,0},
		{{0,0,-10},0,0},
		{{12,0,0},0,1},
	}) {
		pose:=ecs.default_transform(); pose.position=sample.position
		testing.expect(t,ecs.set_transform(&w,emitter,pose))
		gain,pan:=spatial_factors(&w,emitter,player,listener,true)
		testing.expect(t,abs(gain-sample.gain)<0.001 && abs(pan-sample.pan)<0.001,"distance affects volume independently of direction")
	}
	player.spatial=false
	gain,pan:=spatial_factors(&w,emitter,player,listener,true)
	testing.expect(t,gain==1 && pan==0,"nonspatial playback remains centered and unattenuated")
	player.spatial=true
	no_transform:=ecs.create_entity(&w)
	gain,pan=spatial_factors(&w,no_transform,player,listener,true)
	testing.expect(t,gain==1 && pan==0,"an emitter without a transform retains neutral settings")
	gain,pan=spatial_factors(&w,emitter,player,no_transform,true)
	testing.expect(t,gain==1 && pan==0,"a listener without a transform retains neutral settings")
}
