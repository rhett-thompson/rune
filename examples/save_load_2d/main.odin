package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import rune "rune:core"
import "rune:console"
import "rune:ecs"
import "rune:input"
import "rune:save"
import rl "vendor:raylib"

Health :: struct {current: int}
Progress :: struct {coins: int, next_drop: int}

main :: proc() {
	game, ok := rune.init("examples/save_load_2d/project.json")
	if !ok {return}
	defer rune.shutdown(&game)
	assert(ecs.register_component(&game.registry,"Health",Health,Health{100},"Saved player health"))
	assert(rune.configure_saves(&game,save.Options{game_id="rune-checkpoint-demo",game_version=1}))
	assert(save.register_component(&game.saves,&game.registry,ecs.Transform))
	assert(save.register_component(&game.saves,&game.registry,Health))
	console.register(rune.developer_console(&game),"checkpoint","Save demo checkpoint.",save_command)
	console.register(rune.developer_console(&game),"restore","Restore demo checkpoint.",load_command)
	assert(rune.register_system(&game,rune.System{name="checkpoint-demo",start=enter,
		on_save_restored=enter,before_save=capture_globals,ui_update=controls,update=update,draw_ui=draw}))
	rune.run_project(&game)
}

enter :: proc(game: ^rune.Engine, world: ^ecs.World) {
	progress := Progress{}
	value := save.globals(&game.saves)
	if bytes, err := json.marshal(value,allocator=context.temp_allocator); err == nil {
		_ = json.unmarshal(bytes,&progress,allocator=context.temp_allocator)
	}
	ecs.add_resource(world,progress)
}
capture_globals :: proc(game: ^rune.Engine, world: ^ecs.World) {
	progress, found := ecs.resource(world,Progress)
	if !found {return}
	value, ok := ecs.runtime_json(progress^)
	if ok {save.set_globals(&game.saves,value)}
}
controls :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if console.is_open(rune.developer_console(game)) {return}
	buttons := rune.input_state(game)
	if input.frame_action(buttons,"save").pressed {rune.request_save(game,"checkpoint")}
	if input.frame_action(buttons,"load").pressed {rune.request_load(game,"checkpoint")}
	if input.frame_action(buttons,"pause").pressed {rune.set_paused(game,!rune.is_paused(game))}
	if input.frame_action(buttons,"change_room").pressed {
		path := "scenes/room_b.scene.json" if strings.has_suffix(game.active_scene_path,"room_a.scene.json") else "scenes/room_a.scene.json"
		rune.change_scene(game,path)
	}
}
update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if console.is_open(rune.developer_console(game)) {return}
	buttons := rune.input_state(game)
	player, found := ecs.find_entity_by_id(world,"player")
	if !found {return}
	transform, _ := ecs.get(world,player,ecs.Transform)
	direction := [2]f32{input.axis(buttons,"move_x"),input.axis(buttons,"move_y")}
	transform.position.x = math.clamp(transform.position.x + direction.x * 220 * game.delta_time,30,870)
	transform.position.y = math.clamp(transform.position.y + direction.y * 220 * game.delta_time,150,440)
	ecs.set(world,player,transform)
	if input.pressed(buttons,"damage") {
		health, _ := ecs.get(world,player,Health)
		health.current = max(0,health.current-10)
		ecs.set(world,player,health)
	}
	progress, _ := ecs.resource(world,Progress)
	if input.pressed(buttons,"collect") {
		if chest, exists := ecs.find_entity_by_id(world,"chest"); exists {ecs.destroy_entity(world,chest); progress.coins += 10}
	}
	if input.pressed(buttons,"drop") {
		progress.next_drop += 1
		drop := ecs.create_entity(world)
		ecs.set_entity_metadata(world,drop,fmt.tprintf("drop_%d",progress.next_drop),"Dropped coin","",1)
		shape := ecs.default_shape_renderer_2d()
		shape.shape = .circle; shape.radius = 9; shape.color = {245,190,80,255}
		ecs.add(world,&game.registry,drop,transform)
		ecs.add(world,&game.registry,drop,shape)
		save.track_spawn(&game.saves,world,drop)
	}
}
draw :: proc(game: ^rune.Engine, world: ^ecs.World) {
	room := "ROOM A" if strings.has_suffix(game.active_scene_path,"room_a.scene.json") else "ROOM B"
	rl.DrawText(fmt.ctprintf("%s  /  CHECKPOINT SAVES",room),30,24,28,{225,235,250,255})
	rl.DrawText("WASD move   H lose health   E collect chest   Space drop coin",30,70,19,{180,195,215,255})
	rl.DrawText("F5 save   F9 load   Tab change room   P pause",30,98,19,{180,195,215,255})
	player, _ := ecs.find_entity_by_id(world,"player")
	health, _ := ecs.get(world,player,Health)
	progress, found := ecs.resource(world,Progress)
	if found {rl.DrawText(fmt.ctprintf("Health %d   Coins %d%s",health.current,progress.coins,"   PAUSED" if rune.is_paused(game) else ""),30,465,22,{225,235,250,255})}
	result := rune.last_save_result(game)
	message := "Save, change something, then load. Progress survives restarting the demo."
	if result.sequence > 0 {message = "Checkpoint operation completed." if result.ok else rune.last_save_error(game)}
	rl.DrawText(strings.clone_to_cstring(message,context.temp_allocator) or_else "",30,506,17,{145,170,195,255})
}
save_command :: proc(c: ^console.Console, arguments: string) {
	game := (^rune.Engine)(c.user_data)
	if rune.request_save(game,"checkpoint") {console.info(c,"Checkpoint queued for the next frame.")}
	else {console.error(c,rune.last_save_error(game))}
}
load_command :: proc(c: ^console.Console, arguments: string) {
	game := (^rune.Engine)(c.user_data)
	if rune.request_load(game,"checkpoint") {console.info(c,"Restore queued for the next frame.")}
	else {console.error(c,rune.last_save_error(game))}
}
