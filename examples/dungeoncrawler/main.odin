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
	if !ecs.register_component(registry, "DungeonGenerator", Dungeon_Generator, Dungeon_Generator{}, "Procedural dungeon generation settings") ||
	   !ecs.register_component(registry, "DungeonPlayer", Dungeon_Player, Dungeon_Player{}, "First-person dungeon player state") ||
	   !ecs.register_component(registry, "DungeonPresentation", Dungeon_Presentation, Dungeon_Presentation{}, "Dungeon texture settings") {
		fmt.eprintln("Could not register dungeon components")
		return
	}
	if !rune.register_system(&engine, {
		name = "dungeon_crawler",
		start = dungeon_reload_system,
		update = dungeon_update_system,
		draw = dungeon_draw_system,
		on_scene_reloaded = dungeon_reload_system,
	}) {
		fmt.eprintln("Could not register dungeon system")
		return
	}
	rl.DisableCursor()
	if !rune.run(&engine) { fmt.eprintln("Could not run startup scene: ", rune.last_scene_error()) }
}
