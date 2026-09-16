package main

import "core:fmt"
import "core:mem"
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
	if !rune.configure_saves(game,{game_id="rune-third-person",game_version=2,directory="build/saves/third_person_3d",migrate=migrate_course_checkpoint}) ||
	   !register_course_saves(&game.saves,&game.registry) {return false}
	console.register(rune.developer_console(game),"checkpoint","Save inventory and course progress.",course_save_command)
	console.register(rune.developer_console(game),"restore","Restore inventory and course progress.",course_load_command)
	return true
}

// Version 1 authored these obstacles at the scene root. The identity prefab
// parent preserves their saved local poses while namespacing their stable IDs.
course_checkpoint_id :: proc(id: string, allocator: mem.Allocator) -> string {
	for old in ([]string{"ramp", "steep_ramp", "stair_0", "stair_1", "stair_2",
		"stair_3", "stair_4", "stair_5", "stair_landing", "crawl_roof",
		"crawl_side_a", "crawl_side_b", "moving_platform", "pushable_crate", "thin_wall"}) {
		if id == old {return fmt.aprintf("course/%s", id, allocator=allocator)}
	}
	return id
}

migrate_course_checkpoint :: proc(document: ^save.Document, from, to: int, allocator: mem.Allocator) -> bool {
	if from != 1 || to != 2 {return false}
	for key, saved_state in document.scenes {
		if key != "scenes/main.scene.json" {continue}
		state := saved_state
		entities := make(map[string]save.Entity_State, allocator)
		for id, saved_record in state.entities {
			record := saved_record
			renamed := course_checkpoint_id(id, allocator)
			if _, duplicate := entities[renamed]; duplicate {return false}
			record.parent = course_checkpoint_id(record.parent, allocator)
			if renamed != id && record.parent == "" {record.parent = "course"}
			entities[renamed] = record
		}
		state.entities = entities
		for &id in state.baseline {id = course_checkpoint_id(id, allocator)}
		for &id in state.removed {id = course_checkpoint_id(id, allocator)}
		document.scenes[key] = state
	}
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
