package main

import "core:fmt"
import rune "rune:core"
import "rune:console"
import "rune:ecs"
import "rune:input"
import "rune:save"
import example_text "../shared/text"
import rl "vendor:raylib"

register_course_saves :: proc(manager:^save.Manager,registry:^ecs.Component_Registry) -> bool {
	return save.register_component(manager,registry,ecs.Transform) &&
		save.register_component(manager,registry,Inventory) &&
		save.register_component(manager,registry,Door_State) &&
		save.register_component(manager,registry,Respawn_Point) &&
		save.register_component(manager,registry,Health,{capture=capture_health,restore=restore_health}) &&
		save.register_component(manager,registry,ecs.Interactable3D)
}
configure_course_saves :: proc(game:^rune.Engine) -> bool {
	if !rune.configure_saves(game,{game_id="rune-third-person",game_version=1,directory="build/saves/third_person_3d"}) ||
	   !register_course_saves(&game.saves,&game.registry) {return false}
	console.register(rune.developer_console(game),"checkpoint","Save inventory and course progress.",course_save_command)
	console.register(rune.developer_console(game),"restore","Restore inventory and course progress.",course_load_command)
	return true
}
course_save_command :: proc(c:^console.Console,arguments:string) {
	game:=(^rune.Engine)(c.user_data)
	if rune.request_save(game,"checkpoint") {console.info(c,"Checkpoint queued.")}
	else {console.error(c,rune.last_save_error(game))}
}
course_load_command :: proc(c:^console.Console,arguments:string) {
	game:=(^rune.Engine)(c.user_data)
	if rune.request_load(game,"checkpoint") {console.info(c,"Restore queued.")}
	else {console.error(c,rune.last_save_error(game))}
}
sample_checkpoints :: proc(game:^rune.Engine) {
	if console.is_open(rune.developer_console(game)) || !rl.IsWindowFocused() {return}
	controls:=rune.input_state(game)
	if input.pressed(controls,"save_checkpoint") {rune.request_save(game,"checkpoint")}
	else if input.pressed(controls,"load_checkpoint") {rune.request_load(game,"checkpoint")}
}
draw_inventory_ui :: proc(game:^rune.Engine,world:^ecs.World) {
	example_text.draw(fmt.ctprintf("%s   |   F5 save   F9 load",inventory_summary(world,player)),24,195,18,{255,225,145,255})
	result:=rune.last_save_result(game)
	if result.sequence>0 {
		message:="Checkpoint saved." if result.action==.Write else "Checkpoint loaded."
		color:=rl.LIGHTGRAY
		if !result.ok {message=rune.last_save_error(game);color=rl.ORANGE}
		example_text.draw(fmt.ctprintf("%s",message),24,220,16,color)
	}
}
