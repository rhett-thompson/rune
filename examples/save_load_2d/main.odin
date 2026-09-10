package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import rune "rune:core"
import "rune:console"
import "rune:ecs"
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
	if rl.IsKeyPressed(.F5) {rune.request_save(game,"checkpoint")}
	if rl.IsKeyPressed(.F9) {rune.request_load(game,"checkpoint")}
	if rl.IsKeyPressed(.P) {rune.set_paused(game,!rune.is_paused(game))}
	if rl.IsKeyPressed(.TAB) {
		path := "scenes/room_b.scene.json" if strings.has_suffix(game.active_scene_path,"room_a.scene.json") else "scenes/room_a.scene.json"
		rune.change_scene(game,path)
	}
}
update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if console.is_open(rune.developer_console(game)) {return}
	player, found := ecs.find_entity_by_id(world,"player")
	if !found {return}
	transform, _ := ecs.get(world,player,ecs.Transform)
	direction: [2]f32
	if rl.IsKeyDown(.A) {direction.x -= 1}; if rl.IsKeyDown(.D) {direction.x += 1}
	if rl.IsKeyDown(.W) {direction.y -= 1}; if rl.IsKeyDown(.S) {direction.y += 1}
	transform.position.x = math.clamp(transform.position.x + direction.x * 220 * game.delta_time,30,870)
	transform.position.y = math.clamp(transform.position.y + direction.y * 220 * game.delta_time,150,440)
	ecs.set(world,player,transform)
	if rl.IsKeyPressed(.H) {
		health, _ := ecs.get(world,player,Health)
		health.current = max(0,health.current-10)
		ecs.set(world,player,health)
	}
	progress, _ := ecs.resource(world,Progress)
	if rl.IsKeyPressed(.E) {
		if chest, exists := ecs.find_entity_by_id(world,"chest"); exists {ecs.destroy_entity(world,chest); progress.coins += 10}
	}
	if rl.IsKeyPressed(.SPACE) {
		progress.next_drop += 1
		drop := ecs.create_entity(world)
		ecs.set_entity_metadata(world,drop,fmt.tprintf("drop_%d",progress.next_drop),"Dropped coin","",1)
		shape_value: json.Value
		_ = json.unmarshal(transmute([]u8)string(`{"shape":"circle","radius":9,"color":[245,190,80,255]}`),
			&shape_value,allocator=context.temp_allocator)
		position, _ := ecs.runtime_json(transform)
		ecs.add_component(world,&game.registry,drop,"Transform",position)
		ecs.add_component(world,&game.registry,drop,"ShapeRenderer2D",shape_value)
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
