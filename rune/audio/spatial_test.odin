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
	testing.expect(t,abs(gain-0.5)<0.001 && abs(pan-f32(5.0/6.0))<0.001)
	pose,_:=ecs.get_transform(&w,emitter_parent); pose.position.x+=2
	testing.expect(t,ecs.set_transform(&w,emitter_parent,pose))
	gain,pan=spatial_factors(&w,emitter,player,listener,true)
	testing.expect(t,abs(gain)<0.001 && abs(pan-1)<0.001,"moving the emitter parent changes attenuation")
	pose,_=ecs.get_transform(&w,listener_parent); pose.position.x+=2
	testing.expect(t,ecs.set_transform(&w,listener_parent,pose))
	gain,pan=spatial_factors(&w,emitter,player,listener,true)
	testing.expect(t,abs(gain-0.5)<0.001 && abs(pan-f32(5.0/6.0))<0.001,"moving the listener parent updates its reference point")
	player.spatial=false
	gain,pan=spatial_factors(&w,emitter,player,listener,true)
	testing.expect(t,gain==1 && pan==0.5,"nonspatial audio ignores hierarchy")
	player.spatial=true
	gain,pan=spatial_factors(&w,emitter,player,listener,false)
	testing.expect(t,gain==1 && pan==0.5,"a missing listener retains neutral settings")
}
