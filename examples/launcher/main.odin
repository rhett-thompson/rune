package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import rl "vendor:raylib"

Example :: struct {
	name:        string,
	path:        string,
	description: string,
	group:       string,
	collections: []Collection,
}

Collection :: struct {
	name: string,
	path: string,
}

Manifest :: struct {
	examples: []Example,
}

WINDOW_WIDTH :: 1000
WINDOW_HEIGHT :: 820
ROW_HEIGHT :: 52
LIST_TOP :: 112
LIST_BOTTOM :: 756

load_manifest :: proc() -> (Manifest, bool) {
	data, read_error := os.read_entire_file("examples/examples.json", context.allocator)
	if read_error != nil {
		fmt.eprintln("Could not read examples/examples.json")
		return {}, false
	}
	manifest: Manifest
	if json.unmarshal(data, &manifest) != nil || len(manifest.examples) == 0 {
		fmt.eprintln("Could not parse examples/examples.json")
		return {}, false
	}
	return manifest, true
}

run_example :: proc(example: Example) -> int {
	rl.CloseWindow()
	fmt.printf("Building and running %s...\n", example.name)

	command := make([dynamic]string)
	append(&command, "odin")
	append(&command, "run")
	append(&command, fmt.tprintf("examples/%s", example.path))
	append(&command, "-collection:rune=rune")
	output_suffix := ""
	when ODIN_OS == .Windows {
		output_suffix = ".exe"
	}
	if error := os.make_directory_all("build"); error != nil {
		fmt.eprintln("Could not create build directory: ", error)
		return -1
	}
	append(&command, fmt.tprintf("-out:build/%s%s", example.path, output_suffix))
	for collection in example.collections {
		append(&command, fmt.tprintf("-collection:%s=%s", collection.name, collection.path))
	}
	process, start_error := os.process_start(
		{command = command[:], stdin = os.stdin, stdout = os.stdout, stderr = os.stderr},
	)
	if start_error != nil {
		fmt.eprintln("Could not start Odin. Make sure `odin` is on PATH.")
		return -1
	}
	state, wait_error := os.process_wait(process)
	if wait_error != nil {
		fmt.eprintln("Could not wait for the example process.")
		return -1
	}
	return state.exit_code
}

open_window :: proc() {
	rl.SetConfigFlags({.VSYNC_HINT})
	rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "Rune Example Launcher")
	rl.SetTargetFPS(60)
}

main :: proc() {
	manifest, ok := load_manifest()
	if !ok {
		return
	}

	selected := 0
	scroll := 0
	last_exit_code := 0
	has_run := false
	open_window()

	for !rl.WindowShouldClose() {
		visible_rows := (LIST_BOTTOM - LIST_TOP) / ROW_HEIGHT
		max_scroll := max(0, len(manifest.examples) - visible_rows)

		if rl.IsKeyPressed(.DOWN) {
			selected = min(selected + 1, len(manifest.examples) - 1)
		}
		if rl.IsKeyPressed(.UP) {
			selected = max(selected - 1, 0)
		}
		if selected < scroll {
			scroll = selected
		} else if selected >= scroll + visible_rows {
			scroll = selected - visible_rows + 1
		}

		wheel := int(rl.GetMouseWheelMove())
		if wheel != 0 {
			scroll = clamp(scroll - wheel, 0, max_scroll)
		}

		mouse := rl.GetMousePosition()
		launch := rl.IsKeyPressed(.ENTER)
		for visible_index in 0 ..< visible_rows {
			index := scroll + visible_index
			if index >= len(manifest.examples) {
				break
			}
			row := rl.Rectangle {
				x      = 36,
				y      = f32(LIST_TOP + visible_index * ROW_HEIGHT),
				width  = WINDOW_WIDTH - 72,
				height = ROW_HEIGHT - 5,
			}
			if rl.CheckCollisionPointRec(mouse, row) {
				selected = index
				if rl.IsMouseButtonPressed(.LEFT) {
					launch = true
				}
			}
		}

		if launch {
			last_exit_code = run_example(manifest.examples[selected])
			has_run = true
			open_window()
		}

		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{18, 22, 30, 255})
		rl.DrawText("Rune Examples", 36, 28, 32, rl.Color{239, 244, 255, 255})
		rl.DrawText(
			"Choose an example, then press Enter or click. The launcher returns when it closes.",
			36,
			72,
			18,
			rl.Color{154, 164, 184, 255},
		)

		for visible_index in 0 ..< visible_rows {
			index := scroll + visible_index
			if index >= len(manifest.examples) {
				break
			}
			example := manifest.examples[index]
			y := LIST_TOP + visible_index * ROW_HEIGHT
			background := rl.Color{30, 36, 48, 255}
			if index == selected {
				background = rl.Color{49, 82, 125, 255}
			}
			rl.DrawRectangleRounded(
				{x = 36, y = f32(y), width = WINDOW_WIDTH - 72, height = ROW_HEIGHT - 5},
				0.18,
				6,
				background,
			)
			rl.DrawText(fmt.ctprintf("%s", example.name), 52, i32(y + 7), 20, rl.RAYWHITE)
			rl.DrawText(fmt.ctprintf("%s", example.description), 310, i32(y + 10), 16, rl.Color{188, 198, 216, 255})
			rl.DrawText(fmt.ctprintf("%s", example.group), 866, i32(y + 12), 14, rl.Color{154, 164, 184, 255})
		}

		footer := "Up/Down or mouse wheel to navigate"
		if has_run {
			footer = fmt.tprintf("Example exited with code %d", last_exit_code)
		}
		rl.DrawText(fmt.ctprintf("%s", footer), 36, 780, 16, rl.Color{154, 164, 184, 255})
		rl.EndDrawing()
	}

	rl.CloseWindow()
}
