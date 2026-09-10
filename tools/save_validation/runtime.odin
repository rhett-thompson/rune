package main

import "core:fmt"
import rune "rune:core"
import "rune:ecs"
import "rune:save"
import rl "vendor:raylib"

runtime_stage, runtime_updates, runtime_starts, runtime_restores: int
runtime_handle: ecs.Entity
validate_runtime :: proc() {
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	game, ok := rune.init("examples/save_load_2d/project.json")
	assert(ok)
	defer rune.shutdown(&game)
	assert(ecs.register_component(&game.registry,"Health",Health,Health{100},"Health"))
	assert(rune.configure_saves(&game,save.Options{game_id="rune-runtime-validation",game_version=1,directory="build/save-validation/runtime"}))
	assert(save.register_component(&game.saves,&game.registry,Health))
	assert(save.register_component(&game.saves,&game.registry,ecs.Transform))
	assert(rune.register_system(&game,rune.System{name="runtime",start=runtime_start,on_save_restored=runtime_restore,ui_update=runtime_ui,update=runtime_update,draw_ui=runtime_draw}))
	assert(rune.run_project(&game))
	assert(runtime_stage == 5 && runtime_updates == 0 && runtime_starts == 2 && runtime_restores == 2)
	fmt.println("Save runtime validation passed: real frame loop, paused save/load, scene travel, restored callbacks")
}
runtime_start :: proc(game: ^rune.Engine, world: ^ecs.World) {runtime_starts += 1}
runtime_restore :: proc(game: ^rune.Engine, world: ^ecs.World) {runtime_restores += 1}
runtime_update :: proc(game: ^rune.Engine, world: ^ecs.World) {runtime_updates += 1}
runtime_draw :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if runtime_stage != 5 {return}
	frame := rl.LoadImageFromScreen()
	defer rl.UnloadImage(frame)
	// Restored entities must still render through the scene's camera.
	color := rl.GetImageColor(frame,200,280)
	assert(color.b > 200 && color.r < 150)
}
runtime_ui :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if runtime_stage > 0 {check(game.save_result.ok,&game.saves)}
	switch runtime_stage {
	case 0:
		runtime_handle = entity(world,"player")
		assert(ecs.set(world,runtime_handle,Health{42}))
		assert(rune.request_save(game,"frame-test"))
		rune.set_paused(game,true)
	case 1:
		assert(ecs.is_alive(world,runtime_handle))
		assert(ecs.set(world,runtime_handle,Health{11}))
		assert(rune.request_load(game,"frame-test"))
	case 2:
		assert(!ecs.is_alive(world,runtime_handle))
		assert((ecs.get(world,entity(world,"player"),Health) or_else Health{}).current == 42)
		assert(rune.change_scene(game,"scenes/room_b.scene.json"))
	case 3:
		assert((ecs.get(world,entity(world,"player"),Health) or_else Health{}).current == 100)
		assert(rune.change_scene(game,"scenes/room_a.scene.json"))
	case 4:
		assert((ecs.get(world,entity(world,"player"),Health) or_else Health{}).current == 42)
		rune.request_exit(game)
	}
	runtime_stage += 1
}
