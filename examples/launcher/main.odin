package main

import example_text "../shared/text"

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:unicode/utf8"
import "rune:assets"
import "rune:input"
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

run_example :: proc(example: Example) -> (int, string) {
	close_window()
	args, parsed := parse_example_args(os.get_env("RUNE_EXAMPLE_ARGS", context.temp_allocator))
	if !parsed {return -1, "RUNE_EXAMPLE_ARGS contains an unclosed quote."}
	defer free_example_args(args)
	prebuilt := prebuilt_mode(os.get_env("RUNE_EXAMPLES_PREBUILT", context.temp_allocator),
		odin_on_path(os.get_env("PATH", context.temp_allocator)))
	if prebuilt {
		suffix :: ".exe" when ODIN_OS == .Windows else ""
		binary := fmt.tprintf("build/%s%s", example.path, suffix)
		if !os.exists(binary) {
			fmt.eprintf("Missing prebuilt example: %s\n", binary)
			return -1, "Missing prebuilt example. Build or stage this example first."
		}
		fmt.printf("Running %s...\n", example.name)
	} else {
		for collection in example.collections {
			if collection.name == "r3d" && !os.is_dir(fmt.tprintf("%s/r3d", collection.path)) {
				return -1, "Missing r3d. Run: git submodule update --init --recursive"
			}
		}
		if os.is_dir("third_party/r3d-odin/r3d") {
			preparation := []string{"sh", "tools/prepare_r3d.sh"}
			when ODIN_OS == .Windows {preparation = {"cmd.exe", "/d", "/c", "tools\\prepare_r3d.bat"}}
			process, start_error := os.process_start({command = preparation, stdin = os.stdin, stdout = os.stdout, stderr = os.stderr})
			if start_error != nil {return -1, "Could not prepare R3D. See terminal for details."}
			state, wait_error := os.process_wait(process)
			if wait_error != nil || state.exit_code != 0 {return -1, "R3D preparation failed. See terminal for details."}
		}
		if error := os.make_directory_all("build"); error != nil && error != .Exist {
			return -1, "Could not create build directory. See terminal for details."
		}
		fmt.printf("Building and running %s...\n", example.name)
	}
	command := example_command(example, prebuilt, args[:])
	defer free_example_args(command)
	process, start_error := os.process_start({command = command[:], stdin = os.stdin, stdout = os.stdout, stderr = os.stderr})
	if start_error != nil {
		fmt.eprintln("Could not start example: ", start_error)
		return -1, "Could not start example. See terminal for details."
	}
	state, wait_error := os.process_wait(process)
	if wait_error != nil {return -1, "Could not wait for the example process. See terminal for details."}
	return state.exit_code, ""
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
	last_error := ""
	has_run := false
	nav: input.Nav_State
	pad_actions: Pad_Action_State
	open_window()

	for !rl.WindowShouldClose() {
		focused := rl.IsWindowFocused()
		nav_edges: input.Nav_Edges
		if focused {nav_edges = input.nav_update(&nav, rl.GetFrameTime())} else {nav = {}; pad_actions = {}}
		a_down, b_down, a_pressed, b_pressed := false, false, false, false
		for pad: i32 = 0; pad < 4; pad += 1 {
			if !focused || !rl.IsGamepadAvailable(pad) {continue}
			nav_edges.up = nav_edges.up || rl.IsGamepadButtonPressed(pad, .LEFT_FACE_UP)
			nav_edges.down = nav_edges.down || rl.IsGamepadButtonPressed(pad, .LEFT_FACE_DOWN)
			nav_edges.left = nav_edges.left || rl.IsGamepadButtonPressed(pad, .LEFT_FACE_LEFT)
			nav_edges.right = nav_edges.right || rl.IsGamepadButtonPressed(pad, .LEFT_FACE_RIGHT)
			a_down = a_down || rl.IsGamepadButtonDown(pad, .RIGHT_FACE_DOWN)
			b_down = b_down || rl.IsGamepadButtonDown(pad, .RIGHT_FACE_RIGHT)
			a_pressed = a_pressed || rl.IsGamepadButtonPressed(pad, .RIGHT_FACE_DOWN)
			b_pressed = b_pressed || rl.IsGamepadButtonPressed(pad, .RIGHT_FACE_RIGHT)
		}
		pad_launch, pad_exit := false, false
		if focused {pad_launch, pad_exit = pad_actions_update(&pad_actions, a_down, b_down, a_pressed, b_pressed)}
		if pad_exit {break}
		mouse := rl.GetMousePosition()
		mouse_delta := rl.GetMouseDelta()
		clicked := focused && rl.IsMouseButtonPressed(.LEFT)
		next_category := active_category
		if (focused && rl.IsKeyPressed(.RIGHT)) || nav_edges.right {next_category = (active_category + 1) % len(categories)}
		if (focused && rl.IsKeyPressed(.LEFT)) || nav_edges.left {next_category = (active_category + len(categories) - 1) % len(categories)}
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

		if (focused && rl.IsKeyPressed(.DOWN)) || nav_edges.down {
			selected = min(selected + 1, len(filtered) - 1)
		}
		if (focused && rl.IsKeyPressed(.UP)) || nav_edges.up {
			selected = max(selected - 1, 0)
		}
		if selected < scroll {
			scroll = selected
		} else if selected >= scroll + visible_rows {
			scroll = selected - visible_rows + 1
		}

		wheel := int(rl.GetMouseWheelMove()) if focused else 0
		if wheel != 0 {
			scroll = clamp(scroll - wheel, 0, max_scroll)
			selected = clamp(selected, scroll, min(scroll + visible_rows - 1, len(filtered) - 1))
		}

		launch := (focused && rl.IsKeyPressed(.ENTER)) || pad_launch
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
			if focused && (mouse_delta.x != 0 || mouse_delta.y != 0 || clicked) && rl.CheckCollisionPointRec(mouse, row) {
				selected = index
				if clicked {
					launch = true
				}
			}
		}

		if launch {
			last_exit_code, last_error = run_example(manifest.examples[filtered[selected]])
			has_run = true
			nav = {}
			pad_actions = {}
			open_window()
		}

		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{18, 22, 30, 255})
		example_text.draw("Rune Examples", 36, 28, 32, rl.Color{239, 244, 255, 255})
		example_text.draw(
			"D-pad / stick: browse     A / Enter / click: run     B / Esc: exit",
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

		footer := "Left/Right: category     Up/Down: example     A / Enter: run     B / Esc: exit"
		if has_run {
			footer = fmt.tprintf("Example exited with code %d", last_exit_code)
			if last_error != "" {
				footer = last_error
			} else if last_exit_code != 0 {
				footer = fmt.tprintf("Build or example failed with code %d. See terminal for details.", last_exit_code)
			}
		}
		example_text.draw(fmt.ctprintf("%s", footer), 36, 780, 16, rl.Color{154, 164, 184, 255})
		rl.EndDrawing()
	}

	close_window()
}
