package main

import "core:fmt"
import "core:math"
import "core:os"
import rune "rune:core"
import "rune:console"
import "rune:ecs"
import "rune:input"
import example_text "../shared/text"
import rl "vendor:raylib"
import b3 "vendor:box3d"

player:ecs.Entity
follow_camera:ecs.Entity
source:int
visited:[4]bool
camera:=rl.Camera3D{fovy=65,projection=.PERSPECTIVE}
camera_up:V3={0,1,0}
camera_forward:V3={0,0,-1}
camera_turn_speed:f32
facing:V3={0,0,-1}
avatar_up:V3={0,1,0}
avatar_forward:V3={0,0,-1}
avatar_turn_speed:f32
avatar_moving:bool
pitch:f32=0.33
camera_distance:f32=22
actual_distance:f32=22
step_distance,walk_phase:f32
was_grounded,jump_sent,release_sent:bool
gates:[4]V3
smoke_test:bool
frames:int

initialize :: proc(game:^rune.Engine,world:^ecs.World) {
	destroy_planets(world)
	create_planets(world,rune.component_registry(game))
	player,_=ecs.find_entity_by_id(world,"player")
	follow_camera,_=ecs.find_entity_by_id(world,"follow_camera")
	for i in 0..<len(PLANETS) {gates[i]=surface_point(world,i,gate_direction(i))}
	reset_player(world)
}
reset_player :: proc(world:^ecs.World) {
	source=0;visited={};step_distance=0;walk_phase=0;was_grounded=false
	camera_up={0,1,0};camera_forward={0,0,-1};facing={0,0,-1};pitch=0.33
	camera_turn_speed=0
	avatar_up={0,1,0};avatar_forward={0,0,-1};avatar_turn_speed=0;avatar_moving=false
	actual_distance=camera_distance
	ecs.character_controller_3d_teleport(world,player,surface_point(world,0,{0,1,0})+V3{0,0.15,0})
}
shutdown :: proc(game:^rune.Engine,world:^ecs.World) {destroy_planets(world)}
controls :: proc(game:^rune.Engine,world:^ecs.World) {
	jump_sent,release_sent=false,false
	if console.is_open(rune.developer_console(game)) || rune.is_paused(game) {return}
	i:=rune.input_state(game)
	if input.pressed(i,"reset") {reset_player(world)}
	if input.is_down(i,"orbit_camera") || input.is_down(i,"orbit_with_character") {
		yaw:=-input.axis(i,"look_x")*0.004
		camera_forward=unit(camera_forward*math.cos(yaw)+cross(camera_up,camera_forward)*math.sin(yaw))
		pitch=clamp(pitch+input.axis(i,"look_y")*0.004,-0.15,1.1)
	}
	camera_distance=clamp(camera_distance-input.axis(i,"zoom"),4,26)
}
fixed_update :: proc(game:^rune.Engine,world:^ecs.World) {
	pose,_:=ecs.get_transform(world,player)
	source=gravity_source(pose.position,source)
	up:=unit(pose.position-PLANETS[source].center)
	i:=rune.input_state(game)
	forward:=unit(tangent(camera_forward,up))
	right:=unit(cross(forward,up))
	direction:=forward*input.axis(i,"move_z")+right*input.axis(i,"move_x")
	blocked:=console.is_open(rune.developer_console(game)) || rune.is_paused(game)
	if blocked {direction={}}
	ecs.character_controller_3d_move_on_plane(world,player,direction,up,!blocked && input.is_down(i,"sprint"))
	ecs.character_controller_3d_crouch(world,player,!blocked && input.is_down(i,"crouch"))
	if !blocked && !jump_sent && input.pressed(i,"jump") {
		ecs.character_controller_3d_jump(world,player);jump_sent=true
	}
	if !blocked && !release_sent && input.released(i,"jump") {
		ecs.character_controller_3d_release_jump(world,player);release_sent=true
	}
	avatar_moving=length(direction)>0.1
	if avatar_moving {facing=unit(direction)}
	for entity in rocks {
		if native,ok:=ecs.physics_3d_native_body(world,entity);ok {
			p:=b3.Body_GetPosition(native);position:=V3{f32(p.x),f32(p.y),f32(p.z)}
			planet:=gravity_source(position,0)
			force:=unit(PLANETS[planet].center-position)*(18*b3.Body_GetMass(native))
			b3.Body_ApplyForceToCenter(native,{force[0],force[1],force[2]},true)
		}
	}
	if length(pose.position-PLANETS[source].center)>65 {reset_player(world)}
}
post_physics :: proc(game:^rune.Engine,world:^ecs.World) {
	motor,_:=ecs.get_character_controller_3d_state(world,player)
	pose,_:=ecs.get_transform(world,player)
	if motor.grounded {
		for mesh,i in meshes {if motor.support_entity==mesh.entity {visited[i]=true}}
		if !was_grounded {rune.play_audio(game,world,player,"landing")}
		// Use resolved travel in the local ground plane; silence against walls/in air.
		distance:=length(tangent(pose.position-motor.previous_position-motor.support_velocity*game.fixed_delta_time,motor.up))
		if length(motor.world_move)>0.1 && distance>0.002 {
			step_distance+=distance;walk_phase+=distance*3.6
			if step_distance>=1.35 {step_distance=math.mod(step_distance,1.35);rune.play_audio(game,world,player,"footsteps")}
		} else {step_distance=0}
	} else {step_distance=0}
	was_grounded=motor.grounded
}
update :: proc(game:^rune.Engine,world:^ecs.World) {
	motor,_:=ecs.get_character_controller_3d_state(world,player)
	pose,_:=ecs.get_transform(world,player)
	position:=pose.position
	if motor.active {position=motor.previous_position+(position-motor.previous_position)*clamp(game.fixed_accumulator/game.fixed_delta_time,0,1)}
	up:=unit(position-PLANETS[source].center)
	blend:=1-math.exp(-6*game.delta_time)
	transport_camera(up,game.delta_time,orientation_settings(world,follow_camera))
	transport_avatar(up,game.delta_time,orientation_settings(world,player))
	back:=-camera_forward*math.cos(pitch)+camera_up*math.sin(pitch)
	// The aim offset follows the eased horizon as well; raw gravity would move
	// this point 3.2 units instantly when crossing to the opposite gravity well.
	target:=position+camera_up*1.6
	allowed:=camera_distance
	filter:=ecs.Default_Physics_Query_Filter;filter.ignore=player;filter.include_sensors=false
	right:=unit(cross(camera_forward,camera_up))
	for offset in ([5]V3{{},right*0.2,-right*0.2,camera_up*0.2,-camera_up*0.2}) {
		if hit,ok:=ecs.physics_3d_raycast(world,target+offset,back*camera_distance,filter);ok {
			allowed=min(allowed,max(0.1,camera_distance*hit.fraction-0.25))
		}
	}
	if allowed<actual_distance {actual_distance=allowed}
	else {actual_distance+=(allowed-actual_distance)*blend}
	camera.position=rv(target+back*actual_distance);camera.target=rv(target);camera.up=rv(camera_up)
	pose_camera,_:=ecs.get_transform(world,follow_camera)
	pose_camera.position=target+back*actual_distance
	ecs.set_transform(world,follow_camera,pose_camera)
	ecs.set_camera_3d(world,follow_camera,{target=target,up=camera_up,fovy=camera.fovy,active=true})
	frames+=1
	if smoke_test && frames==90 {rl.TakeScreenshot("build/planetary_3d.png");rune.request_exit(game)}
}
main :: proc() {
	for arg in os.args[1:] {if arg=="--smoke-test" {smoke_test=true}}
	game,ok:=rune.init("examples/planetary_3d/project.json")
	if !ok {fmt.eprintln("Could not load planetary project");os.exit(1)}
	defer rune.shutdown(&game)
	assert(register_planetary_components(rune.component_registry(&game)))
	if !example_text.init(&game.assets) {fmt.eprintln("Could not load example font");return}
	assert(rune.register_system(&game,{name="pocket_planets",start=initialize,ui_update=controls,
		fixed_update=fixed_update,post_physics=post_physics,update=update,draw=draw,draw_ui=draw_ui,
		on_scene_reloaded=initialize,shutdown=shutdown}))
	if !rune.run(&game) {fmt.eprintln(rune.last_scene_error());os.exit(1)}
}
