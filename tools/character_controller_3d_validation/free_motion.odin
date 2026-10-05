package main

import "core:fmt"
import "rune:ecs"
import "rune:scene"

validate_free_motion :: proc(r: ^ecs.Component_Registry) {
	for fps in ([3]int{30,60,120}) {
		w:=ecs.init()
		floor(&w,r); box(&w,r,{3,2,0},{0.1,20,20})
		e:=player(&w,r); step(&w,3)
		config,_:=ecs.get_character_controller_3d(&w,e)
		ecs.character_controller_3d_crouch(&w,e,true)
		ecs.character_controller_3d_jump(&w,e)
		assert(ecs.character_controller_3d_set_free_motion(&w,e,true,{12,8,0}))
		for _ in 0..<fps {ecs.physics_3d_update(&w,1/f32(fps))}
		p:=pose(&w,e); s:=state(&w,e)
		assert(abs(p.position[0]-12)<0.001 && abs(p.position[1]-8)<0.001,"free motion bypasses wall/gravity and is independent of frame rate")
		assert(s.free_motion && s.active && !s.grounded && !s.crouched && s.support_entity==0 && !s.jump_requested,"free motion clears walking/support commands")
		assert(abs(s.previous_position[0]-(12-12/f32(60)))<0.001,"camera retains the previous fixed-step position")
		assert(ecs.character_controller_3d_set_free_motion(&w,e,true))
		step(&w,60); assert(pose(&w,e)==p && state(&w,e).velocity==[3]f32{},"zero velocity hovers without drift")
		assert(!ecs.character_controller_3d_set_free_motion(&w,e,true,{transmute(f32)u32(0x7fc00000),0,0}),"nonfinite velocity is rejected")
		assert(ecs.character_controller_3d_set_free_motion(&w,e,false))
		assert(!state(&w,e).free_motion && state(&w,e).velocity==[3]f32{},"resuming discards flight momentum")
		step(&w,120); assert(state(&w,e).grounded && abs(pose(&w,e).position[1])<0.03,"normal gravity and grounding resume")
		box(&w,r,{15,2,0},{0.1,4,20})
		ecs.character_controller_3d_move(&w,e,{1,0}); step(&w,120)
		assert(pose(&w,e).position[0]>14.4 && pose(&w,e).position[0]<14.65,"normal collision resumes")
		after,_:=ecs.get_character_controller_3d(&w,e); assert(after==config,"free motion never rewrites authored motor configuration")
		assert(ecs.character_controller_3d_set_free_motion(&w,e,true,{2,0,0}))
		ecs.set_enabled(&w,e,false); assert(!state(&w,e).free_motion)
		assert(!ecs.character_controller_3d_set_free_motion(&w,e,true),"disabled controllers reject free motion")
		ecs.set_enabled(&w,e,true); assert(!state(&w,e).free_motion)
		assert(ecs.character_controller_3d_set_free_motion(&w,e,true))
		assert(ecs.character_controller_3d_teleport(&w,e,{0,1,0}) && !state(&w,e).free_motion,"teleport resets the override")
		assert(ecs.character_controller_3d_set_free_motion(&w,e,true))
		ecs.remove_component(&w,e,"CharacterController3D"); assert(!ecs.character_controller_3d_set_free_motion(&w,e,true))
		ecs.destroy(&w)
	}
	w,ok:=scene.load("tools/character_controller_3d_validation/fixtures/main.scene.json",r); assert(ok)
	defer ecs.destroy(&w)
	e,_:=ecs.find_entity_by_id(&w,"player")
	assert(ecs.character_controller_3d_set_free_motion(&w,e,true,{1,2,3})); step(&w)
	copy,loaded:=scene.load("tools/character_controller_3d_validation/fixtures/main.scene.json",r); assert(loaded)
	assert(ecs.apply_value_snapshot(&w,&copy)); ecs.destroy(&copy)
	assert(state(&w,e).free_motion && state(&w,e).velocity==[3]f32{1,2,3},"value reload retains runtime free motion")
	ecs.physics_3d_shutdown(&w); assert(!state(&w,e).free_motion,"shutdown clears free motion")
	fmt.println("PASS free motion, hover, timing, resume, reload, and lifecycle")
}
