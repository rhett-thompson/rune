package main

import "core:fmt"
import example_text "../shared/text"
import "rune:console"
import rune "rune:core"
import "rune:ecs"
import "rune:ui"
import rl "vendor:raylib"

movement_ui:ui.Context
movement_default_agent:ecs.NavAgent3D
movement_default_motor:ecs.CharacterController3D
movement_defaults_ready:bool
movement_pointer_owned:bool
movement_panel_open:=true

reset_movement_panel :: proc(world:^ecs.World) {
	ui.reset_focus(&movement_ui)
	movement_pointer_owned=false
	if movement_defaults_ready {return}
	agent,found:=ecs.find_entity_by_id(world,"agent")
	if !found {movement_defaults_ready=false;return}
	agent_ok,motor_ok:bool
	movement_default_agent,agent_ok=ecs.get(world,agent,ecs.NavAgent3D)
	movement_default_motor,motor_ok=ecs.get(world,agent,ecs.CharacterController3D)
	movement_defaults_ready=agent_ok && motor_ok
}

movement_slider :: proc(id,label,units:string,value:^f32,minimum,maximum,step:f32) {
	ui.panel(&movement_ui,fmt.tprintf("%s-row",id),{
		layout={sizing={width=ui.grow({}),height=ui.fit({})},layoutDirection=.TopToBottom,childGap=3},
	})
	ui.label(&movement_ui,fmt.tprintf("%s   %.2f %s",label,value^,units),movement_ui.style.text,16)
	ui.slider(&movement_ui,id,value,minimum,max(maximum,value^),step)
	ui.end_panel(&movement_ui)
}

movement_toggle :: proc(id,label:string,value:^bool) {
	if ui.button(&movement_ui,id,fmt.tprintf("%s: %s",label,"ON" if value^ else "OFF")) {value^=!value^}
}

// Build before world input, even while paused or the console has focus. Only
// changed components are committed, so idle UI frames do not force a repath.
update_movement_panel :: proc(game:^rune.Engine,world:^ecs.World) -> bool {
	if movement_ui.native==nil {return false}
	ui.set_font(&movement_ui,example_text.font())
	controls:=ui.read_input(rune.input_state(game))
	controls.blocked=console.is_open(rune.developer_console(game)) || !rl.IsWindowFocused()
	was_active:=movement_ui.active_id!=0
	if !ui.begin(&movement_ui,{f32(rl.GetScreenWidth()),f32(rl.GetScreenHeight())},controls,game.frame_delta_time) {return false}
	agent,found:=ecs.find_entity_by_id(world,"agent")
	config,agent_ok:=ecs.get(world,agent,ecs.NavAgent3D)
	motor,motor_ok:=ecs.get(world,agent,ecs.CharacterController3D)
	ui.panel(&movement_ui,"movement-screen",{layout={sizing={width=ui.grow({}),height=ui.grow({})}}})
	ui.panel(&movement_ui,"movement-panel",{
		layout={sizing={width=ui.fixed(288 if movement_panel_open else 210),height=ui.fit({})},layoutDirection=.TopToBottom,padding=ui.padding(16),childGap=6},
		floating={attachTo=.Root,attachment={element=.RightTop,parent=.RightTop},offset={-24,20}},
		backgroundColor={22,32,46,245},cornerRadius=ui.corners(10),
		border={color={58,81,103,255},width={left=1,right=1,top=1,bottom=1}},
	})
	movement_ui.style.height=30
	movement_ui.style.font_size=14
	ui.panel(&movement_ui,"movement-header",{layout={sizing={width=ui.grow({}),height=ui.fit({})},childGap=12,childAlignment={y=.Center}}})
	ui.label(&movement_ui,"Movement",movement_ui.style.text,22)
	if ui.button(&movement_ui,"movement-visibility","Hide" if movement_panel_open else "Show") {movement_panel_open=!movement_panel_open}
	ui.end_panel(&movement_ui)
	if movement_panel_open {ui.label(&movement_ui,"Drag to tune, even while paused",movement_ui.style.muted,14)}
	if movement_panel_open && found && agent_ok && motor_ok {
		before_config,before_motor:=config,motor
		movement_slider("movement-speed","Speed","units/s",&config.speed,0,8,0.1)
		movement_slider("movement-acceleration","Acceleration","units/s²",&motor.acceleration,0.1,40,0.5)
		movement_slider("movement-braking","Braking","units/s²",&motor.braking,0.1,40,0.5)
		movement_slider("movement-turning","Turning","degrees/s",&config.angular_speed,0,720,15)
		movement_slider("movement-stopping","Stopping distance","units",&config.stopping_distance,0,2,0.05)
		movement_slider("movement-waypoint","Waypoint tolerance","units",&config.waypoint_distance,0,0.5,0.01)
		movement_slider("movement-slope","Max slope","degrees",&config.max_slope,0,45,1)
		movement_ui.style.height=30
		movement_ui.style.font_size=14
		ui.panel(&movement_ui,"movement-toggles",{layout={sizing={width=ui.grow({}),height=ui.fit({})},childGap=6}})
		movement_toggle("movement-facing","Facing",&config.update_rotation)
		movement_toggle("movement-auto-braking","Braking",&config.auto_braking)
		ui.end_panel(&movement_ui)
		movement_toggle("movement-corners","Corner slowdown",&config.corner_slowdown)
		if ui.button(&movement_ui,"movement-reset","Reset movement settings",movement_defaults_ready) {
			config.speed=movement_default_agent.speed
			config.angular_speed=movement_default_agent.angular_speed
			config.stopping_distance=movement_default_agent.stopping_distance
			config.waypoint_distance=movement_default_agent.waypoint_distance
			config.max_slope=movement_default_agent.max_slope
			config.update_rotation=movement_default_agent.update_rotation
			config.auto_braking=movement_default_agent.auto_braking
			config.corner_slowdown=movement_default_agent.corner_slowdown
			motor.acceleration=movement_default_motor.acceleration
			motor.braking=movement_default_motor.braking
			motor.move_speed=movement_default_motor.move_speed
			motor.max_slope_angle=movement_default_motor.max_slope_angle
		}
		// Keep the motor cap and slope limit in sync with navigation. Existing
		// dimensions and the active destination are retained by the setters.
		if config.speed!=before_config.speed {motor.move_speed=config.speed}
		if config.max_slope!=before_config.max_slope {motor.max_slope_angle=config.max_slope}
		if motor!=before_motor {ecs.set(world,agent,motor)}
		if config!=before_config {ecs.set(world,agent,config)}
	} else if movement_panel_open {ui.label(&movement_ui,"Navigation agent unavailable",movement_ui.style.muted,16)}
	if movement_panel_open {ui.label(&movement_ui,"Changes last for this session.\nTurning at zero holds facing.",movement_ui.style.muted,13)}
	ui.end_panel(&movement_ui)
	ui.end_panel(&movement_ui)
	if !ui.finish(&movement_ui) {console.error(rune.developer_console(game),ui.last_error(&movement_ui))}
	if controls.blocked {movement_pointer_owned=false;return false}
	bounds,has_bounds:=ui.bounds(&movement_ui,"movement-panel")
	hovered:=has_bounds && rl.CheckCollisionPointRec(controls.pointer,bounds)
	buttons_down:=controls.pointer_down || rl.IsMouseButtonDown(.RIGHT) || rl.IsMouseButtonDown(.MIDDLE)
	owned:=movement_pointer_owned || was_active || movement_ui.active_id!=0 || hovered
	movement_pointer_owned=owned && buttons_down
	return owned
}

draw_movement_panel :: proc(game:^rune.Engine,world:^ecs.World) {ui.draw(&movement_ui)}
