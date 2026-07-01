package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import rune "rune:core"
import "rune:ecs"
import rl "vendor:raylib"

main :: proc() {
	project_path := "examples/dungeoncrawler/project.json"
	if !os.exists(project_path) {
		exe_dir, err := os.get_executable_directory(context.allocator)
		if err == nil {
			project_path, _ = filepath.join({exe_dir, "..", "examples", "dungeoncrawler", "project.json"})
		}
	}
	engine, ok := rune.init(project_path)
	if !ok {
		fmt.eprintln("Could not load dungeon crawler project: ", project_path)
		return
	}
	defer rune.shutdown(&engine)
	registry := rune.component_registry(&engine)
	if !ecs.register_component(registry, {name="DungeonGenerator", description="Procedural dungeon generation settings"}) ||
	   !ecs.register_component(registry, {name="DungeonPlayer", description="First-person dungeon player state"}) ||
	   !ecs.register_component(registry, {name="DungeonPresentation", description="Dungeon texture settings"}) ||
	   !ecs.register_component(registry, {name="DungeonEnemy", description="Runtime dungeon enemy state"}) {
		fmt.eprintln("Could not register dungeon components")
		return
	}
	project_dir, _ := filepath.split(project_path)
	scene_path, _ := filepath.join({project_dir, "scenes", "main.scene.json"})
	world, scene_ok := rune.load_scene(&engine, scene_path)
	if !scene_ok || !initialize_dungeon(&engine, &world) {
		fmt.eprintln("Could not initialize dungeon scene")
		return
	}
	if !rune.register_system(&engine, {
		name = "dungeon_crawler",
		update = dungeon_update_system,
		draw = dungeon_draw_system,
		on_scene_reloaded = dungeon_reload_system,
	}) {
		fmt.eprintln("Could not register dungeon system")
		return
	}
	rl.DisableCursor()
	rune.run_scene(&engine, &world)
}
