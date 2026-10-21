package main

import "core:fmt"
import "core:os"
import rune "rune:core"

main :: proc() {
	if code := run_game(); code != 0 {os.exit(code)}
}

run_game :: proc() -> int {
	engine, ok := rune.init_project()
	if !ok {
		project_path, path_error := rune.executable_project_path(allocator = context.temp_allocator)
		if path_error != nil {
			fmt.eprintln("Could not resolve project.json relative to the executable: ", path_error)
		} else {
			fmt.eprintln("Could not load project: ", project_path)
		}
		fmt.eprintln("Player builds need project.json and content beside the executable; development builds use the parent of build/.")
		return 1
	}
	defer rune.shutdown(&engine)

	if !rune.run(&engine) {
		fmt.eprintln("Could not run startup scene: ", rune.last_scene_error())
		return 1
	}
	return 0
}
