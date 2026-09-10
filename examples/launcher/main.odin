package main

import example_text "../shared/text"

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:unicode/utf8"
import "rune:assets"
import rl "vendor:raylib"

font_assets: assets.Asset_Manager

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

Category :: struct {
	name: string,
	examples: [dynamic]int, // Indices into the manifest, also used when launching.
}

build_categories :: proc(examples: []Example) -> [dynamic]Category {
	categories := make([dynamic]Category)
	append(&categories, Category{name = "All"})
	for example, index in examples {
		append(&categories[0].examples, index)
		category := -1
		for candidate in 1 ..< len(categories) {
			if categories[candidate].name == example.group {category = candidate; break}
		}
		if category < 0 {
			category = len(categories)
			append(&categories, Category{name = example.group})
		}
		append(&categories[category].examples, index)
	}
	// Keep the learning order familiar; additional manifest groups follow these.
	next := 1
	preferred_order := [4]string{"Basics", "2D", "3D", "Games"}
	for name in preferred_order {
		for index in next ..< len(categories) {
			if categories[index].name == name {
				categories[next], categories[index] = categories[index], categories[next]
				next += 1
				break
			}
		}
	}
	return categories
}

WINDOW_WIDTH :: 1000
WINDOW_HEIGHT :: 820
ROW_HEIGHT :: 52
TABS_TOP :: 110
TAB_HEIGHT :: 40
TAB_GAP :: 8
LIST_TOP :: 170
LIST_BOTTOM :: 756
NAME_X :: 52
DESCRIPTION_X :: 310
GROUP_X :: 866
COLUMN_GAP :: 20

tab_bounds :: proc(index, count: int) -> rl.Rectangle {
	width := (f32(WINDOW_WIDTH - 72) - f32(count - 1) * TAB_GAP) / f32(count)
	return {36 + f32(index) * (width + TAB_GAP), TABS_TOP, width, TAB_HEIGHT}
}

// Align mixed font sizes on one baseline, using the font's flat capital glyph
// instead of offsets tuned for raylib's old bitmap font.
draw_row_label :: proc(value: string, x, max_width: i32, baseline: f32, size: i32, color: rl.Color) {
	font := example_text.font()
	cap := rl.GetGlyphInfo(font, 'H')
	cap_rect := rl.GetGlyphAtlasRec(font, 'H')
	scale := f32(size) / f32(font.baseSize)
	y := baseline - (f32(cap.offsetY) + cap_rect.height) * scale
	label := fmt.ctprintf("%s", value)
	if example_text.measure(label, size) > max_width {
		remaining := value
		for len(remaining) > 0 {
			_, count := utf8.decode_last_rune(remaining)
			remaining = remaining[:len(remaining) - count]
			label = fmt.ctprintf("%s...", remaining)
			if example_text.measure(label, size) <= max_width {break}
		}
	}
	rl.DrawTextEx(font, label, {f32(x), y}, f32(size), example_text.SPACING, color)
}

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
	// Filtered tabs inherit this order and keep their launch indices in sync.
	slice.sort_by(manifest.examples, proc(a, b: Example) -> bool {return a.name < b.name})
	return manifest, true
}

run_example :: proc(example: Example) -> int {
	close_window()
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
	// Keep the window and UI in logical units on scaled displays.
	rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_HIGHDPI})
	rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "Rune Example Launcher")
	rl.SetTargetFPS(60)
	font_assets = assets.init("examples/launcher")
	assert(example_text.init(&font_assets), "Could not load shared example font")
}

close_window :: proc() {
	assets.shutdown(&font_assets)
	rl.CloseWindow()
}

main :: proc() {
	manifest, ok := load_manifest()
	if !ok {
		return
	}

	categories := build_categories(manifest.examples)
	defer {
		for category in categories {delete(category.examples)}
		delete(categories)
	}
	active_category := 0
	selected := 0
	scroll := 0
	last_exit_code := 0
	has_run := false
	open_window()

	for !rl.WindowShouldClose() {
		mouse := rl.GetMousePosition()
		mouse_delta := rl.GetMouseDelta()
		clicked := rl.IsMouseButtonPressed(.LEFT)
		next_category := active_category
		if rl.IsKeyPressed(.RIGHT) {next_category = (active_category + 1) % len(categories)}
		if rl.IsKeyPressed(.LEFT) {next_category = (active_category + len(categories) - 1) % len(categories)}
		for _, index in categories {
			if clicked && rl.CheckCollisionPointRec(mouse, tab_bounds(index, len(categories))) {
				next_category = index
			}
		}
		if next_category != active_category {
			active_category = next_category
			selected, scroll = 0, 0
		}
		filtered := categories[active_category].examples[:]
		visible_rows := (LIST_BOTTOM - LIST_TOP) / ROW_HEIGHT
		max_scroll := max(0, len(filtered) - visible_rows)

		if rl.IsKeyPressed(.DOWN) {
			selected = min(selected + 1, len(filtered) - 1)
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
			selected = clamp(selected, scroll, min(scroll + visible_rows - 1, len(filtered) - 1))
		}

		launch := rl.IsKeyPressed(.ENTER)
		for visible_index in 0 ..< visible_rows {
			index := scroll + visible_index
			if index >= len(filtered) {
				break
			}
			row := rl.Rectangle {
				x      = 36,
				y      = f32(LIST_TOP + visible_index * ROW_HEIGHT),
				width  = WINDOW_WIDTH - 72,
				height = ROW_HEIGHT - 5,
			}
			if (mouse_delta.x != 0 || mouse_delta.y != 0 || clicked) && rl.CheckCollisionPointRec(mouse, row) {
				selected = index
				if clicked {
					launch = true
				}
			}
		}

		if launch {
			last_exit_code = run_example(manifest.examples[filtered[selected]])
			has_run = true
			open_window()
		}

		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{18, 22, 30, 255})
		example_text.draw("Rune Examples", 36, 28, 32, rl.Color{239, 244, 255, 255})
		example_text.draw(
			"Choose a category, then press Enter or click an example to run it.",
			36,
			72,
			18,
			rl.Color{154, 164, 184, 255},
		)

		for category, index in categories {
			bounds := tab_bounds(index, len(categories))
			active := index == active_category
			hovered := rl.CheckCollisionPointRec(mouse, bounds)
			background := rl.Color{49, 82, 125, 255} if active else
				rl.Color{39, 48, 64, 255} if hovered else rl.Color{30, 36, 48, 255}
			rl.DrawRectangleRounded(bounds, 0.2, 6, background)
			font := example_text.font()
			cap_height := rl.GetGlyphAtlasRec(font, 'H').height * 18 / f32(font.baseSize)
			baseline := bounds.y + (bounds.height + cap_height) * 0.5
			draw_row_label(category.name, i32(bounds.x) + 16, i32(bounds.width) - 64,
				baseline, 18, rl.RAYWHITE if active else rl.Color{188, 198, 216, 255})
			count := fmt.tprintf("%d", len(category.examples))
			count_width := example_text.measure(fmt.ctprintf("%s", count), 14)
			draw_row_label(count, i32(bounds.x + bounds.width) - 16 - count_width, count_width,
				baseline, 14, {154, 184, 220, 255})
		}

		for visible_index in 0 ..< visible_rows {
			index := scroll + visible_index
			if index >= len(filtered) {
				break
			}
			example := manifest.examples[filtered[index]]
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
			font := example_text.font()
			cap_height := rl.GetGlyphAtlasRec(font, 'H').height * 20 / f32(font.baseSize)
			baseline := f32(y) + (f32(ROW_HEIGHT - 5) + cap_height) * 0.5
			draw_row_label(example.name, NAME_X, DESCRIPTION_X - NAME_X - COLUMN_GAP, baseline, 20, rl.RAYWHITE)
			draw_row_label(example.description, DESCRIPTION_X, GROUP_X - DESCRIPTION_X - COLUMN_GAP,
				baseline, 16, {188, 198, 216, 255})
			draw_row_label(example.group, GROUP_X, WINDOW_WIDTH - 52 - GROUP_X,
				baseline, 14, {154, 164, 184, 255})
		}

		footer := "Left/Right: category     Up/Down or wheel: example     Enter: run"
		if has_run {
			footer = fmt.tprintf("Example exited with code %d", last_exit_code)
		}
		example_text.draw(fmt.ctprintf("%s", footer), 36, 780, 16, rl.Color{154, 164, 184, 255})
		rl.EndDrawing()
	}

	close_window()
}
