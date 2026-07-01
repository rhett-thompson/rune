package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import rune "rune:core"
import rl "vendor:raylib"

main :: proc() {
	project_path := "examples/dungeoncrawler/project.json"
	if !os.exists(project_path) {
		executable_directory, path_error := os.get_executable_directory(context.allocator)
		if path_error == nil {
			project_path, _ = filepath.join({
				executable_directory, "..", "examples", "dungeoncrawler", "project.json",
			})
		}
	}
	engine, ok := rune.init(project_path)
	if !ok {
		fmt.eprintln("Could not load dungeon crawler project: ", project_path)
		return
	}
	defer rune.shutdown(&engine)
	project_directory, _ := filepath.split(project_path)
	load_assets(&engine, project_directory)
	defer unload_audio()
	reset_game(true)
	rl.DisableCursor()
	rune.run(&engine, update_game, draw_game)
}
