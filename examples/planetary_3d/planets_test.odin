package main

import "core:fmt"
import "core:encoding/json"
import "core:testing"
import "core:math"
import "rune:ecs"

@(test)
planetary_routes :: proc(t:^testing.T) {
	r:=ecs.init_registry();defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	w:=ecs.init();defer ecs.destroy(&w)
	create_planets(&w,&r);defer destroy_planets(&w)
	e:=ecs.create_entity(&w)
	assert(ecs.add_component(&w,&r,e,"Transform",json.Object{}))
	c:=ecs.default_character_controller_3d()
	c.gravity=18;c.jump_speed=16;c.max_slope_angle=58;c.ground_snap_distance=0.35
	assert(ecs.add(&w,&r,e,c))
	for p,i in PLANETS {
		mesh:=meshes[i]
		testing.expect(t,len(mesh.indices)==960,"320 terrain triangles per icosahedron")
		testing.expect(t,len(mesh.vertices)==162,"shared collision vertices welded")
		for j:=0;j<len(mesh.indices);j+=3 {
			a,b,c:=mesh.vertices[mesh.indices[j]],mesh.vertices[mesh.indices[j+1]],mesh.vertices[mesh.indices[j+2]]
			testing.expect(t,dot(cross(b-a,c-a),a+b+c)>0,"outward triangle winding")
		}
		up:=gate_direction(i)
		start:=surface_point(&w,i,up)
		ecs.character_controller_3d_teleport(&w,e,start+up*0.1)
		current:=i
		for _ in 0..<45 {
			pose,_:=ecs.get_transform(&w,e)
			ecs.character_controller_3d_move_on_plane(&w,e,{},unit(pose.position-p.center))
			ecs.physics_3d_update(&w,1.0/60)
		}
		state,_:=ecs.get_character_controller_3d_state(&w,e)
		testing.expect(t,state.grounded,"launch marker is walkable")
		ecs.character_controller_3d_jump(&w,e)
		landed:=false
		for frame in 0..<480 {
			pose,_:=ecs.get_transform(&w,e)
			current=gravity_source(pose.position,current)
			ecs.character_controller_3d_move_on_plane(&w,e,{},unit(pose.position-PLANETS[current].center))
			ecs.physics_3d_update(&w,1.0/60)
			state,_=ecs.get_character_controller_3d_state(&w,e)
			if frame>3 && state.grounded {
				landed=state.support_entity==meshes[(i+1)%4].entity
				break
			}
		}
		testing.expect(t,landed,fmt.tprintf("held jump transfers from world %d to %d",i,(i+1)%4))
		// Walk over the ridges, around the equator, and onto the underside.
		ecs.character_controller_3d_teleport(&w,e,surface_point(&w,i,{0,1,0})+V3{0,0.1,0})
		ground_frames:=0
		reached_underside:=false
		for _ in 0..<900 {
			pose,_:=ecs.get_transform(&w,e)
			up:=unit(pose.position-p.center)
			ecs.character_controller_3d_move_on_plane(&w,e,unit(cross(up,V3{0,0,1})),up)
			ecs.physics_3d_update(&w,1.0/60)
			state,_=ecs.get_character_controller_3d_state(&w,e)
			if state.grounded {ground_frames+=1}
			if up[1]<-0.8 {reached_underside=true}
		}
		testing.expect(t,ground_frames>850,fmt.tprintf("world %d maintains ground contact around faceted terrain (%d/900)",i,ground_frames))
		testing.expect(t,reached_underside,fmt.tprintf("world %d can be walked onto its underside",i))
	}
	// Exercise the actual camera handover at low and high render rates.
	one_second:[3]V3
	for fps,index in ([3]int{30,60,144}) {
		camera_up={0,1,0};camera_forward={0,0,-1};camera_turn_speed=0
		avatar_up={0,1,0};avatar_forward={0,0,-1};avatar_turn_speed=0;avatar_moving=false
		for frame in 0..<fps*4 {
			previous:=camera_up
			transport_camera({0,-1,0},1/f32(fps))
			transport_avatar({0,-1,0},1/f32(fps))
			testing.expect(t,length(camera_up-avatar_up)<0.001,"avatar eases through a gravity reversal with the camera")
			turn:=math.acos(clamp(dot(previous,camera_up),-1,1))
			testing.expect(t,turn<=2.4/f32(fps)+0.001,"horizon rotation stays within its speed limit")
			if frame==0 {testing.expect(t,turn<0.004,"handover eases in instead of snapping")}
			if frame==fps-1 {one_second[index]=camera_up}
		}
		testing.expect(t,dot(camera_up,V3{0,-1,0})>0.999,"camera settles into opposing gravity")
		testing.expect(t,math.abs(dot(camera_forward,camera_up))<0.001,"orbit heading remains tangent")
		testing.expect(t,math.abs(dot(avatar_forward,avatar_up))<0.001,"avatar retains an orthogonal orientation")
	}
	testing.expect(t,length(one_second[0]-one_second[1])<0.01 && length(one_second[0]-one_second[2])<0.01,"handover timing is consistent across render rates")
	camera_up={0,1,0};camera_forward={0,0,-1};camera_turn_speed=0
	for frame in 0..<12 {
		// Almost-antipodal gravity varies on alternating sides of the pole.
		transport_camera(unit({0.0001 if frame%2==0 else -0.0001,-1,0}),1.0/60)
	}
	testing.expect(t,dot(camera_forward,V3{0,0,-1})>0.999,"near-opposite gravity keeps a stable flip direction")
	avatar_up={0,1,0};avatar_forward={0,0,-1};avatar_turn_speed=0;avatar_moving=true
	facing={0,0,1}
	transport_avatar({0,1,0},1.0/60)
	testing.expect(t,dot(avatar_forward,V3{0,0,-1})>0.98,"reversing movement eases avatar facing")
	for _ in 0..<90 {transport_avatar({0,1,0},1.0/60)}
	testing.expect(t,dot(avatar_forward,facing)>0.999,"avatar settles facing movement")
	avatar_moving=false
	before:=avatar_forward
	camera_forward={1,0,0}
	transport_avatar({0,1,0},1.0/60)
	testing.expect(t,length(before-avatar_forward)<0.001,"idle avatar does not turn with camera orbit")
}
