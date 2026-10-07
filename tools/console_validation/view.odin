package main

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import "rune:console"
import rl "vendor:raylib"

runtime_view_console: ^console.Console

runtime_view_measure :: proc(text: string, size: f32) -> f32 {
	return console.text_width(runtime_view_console, text, size)
}

console_view_set_input :: proc(dev: ^console.Console, value: string, caret: int) {
	copy(dev.input[:], value)
	dev.input_len = len(value)
	console.set_input_caret(dev, caret)
	dev.edit_revision += 1
}

// The runtime console capture command deliberately omits its own overlay.
// Draw the overlay directly, then read it back after both presentation buffers
// have received the same frame.
console_snapshot :: proc(dev: ^console.Console, path: cstring = nil) -> rl.Image {
	for _ in 0 ..< 3 {
		rl.BeginDrawing()
		rl.ClearBackground({8, 12, 18, 255})
		console.draw(dev)
		rl.EndDrawing()
	}
	image := rl.LoadImageFromScreen()
	assert(image.data != nil)
	if path != nil {assert(rl.ExportImage(image, path), "console overlay screenshot must be saved")}
	return image
}

console_caret_is_visible :: proc(dev: ^console.Console, image: rl.Image) -> bool {
	layout := console.view_layout(f32(image.width), f32(image.height))
	x := layout.input.x + 32 + console.text_width(dev,
		string(dev.input[:dev.input_caret]), console.Font_Size) - dev.renderer.input_scroll
	for y in int(layout.input.y + 12) ..< int(layout.input.y + 28) {
		for pixel_x in int(math.floor(x)) - 1 ..< int(math.ceil(x)) + 3 {
			if pixel_x < 0 || pixel_x >= int(image.width) {continue}
			pixel := rl.GetImageColor(image, i32(pixel_x), i32(y))
			if pixel.r < 160 && pixel.g > 180 && pixel.b > 130 {return true}
		}
	}
	return false
}

console_text_is_clipped :: proc(image: rl.Image, panel: rl.Rectangle) -> bool {
	for y in 0 ..< int(image.height) {
		for x in 0 ..< int(image.width) {
			point := rl.Vector2{f32(x) + 0.5, f32(y) + 0.5}
			if rl.CheckCollisionPointRec(point, panel) {continue}
			pixel := rl.GetImageColor(image, i32(x), i32(y))
			// Panel edges and its shadow are dark; text/caret pixels are bright.
			if pixel.r > 120 || pixel.g > 120 || pixel.b > 120 {return false}
		}
	}
	return true
}

validate_console_clipboard :: proc(dev: ^console.Console) {
	// Retain clipboard text only in memory and restore it before assertions or
	// screenshots. The local Windows runner also preserves nontext formats.
	original, save_error := strings.clone_from_cstring(rl.GetClipboardText())
	assert(save_error == nil)
	defer delete(original)
	original_c, conversion_error := strings.clone_to_cstring(original)
	assert(conversion_error == nil)
	defer delete(original_c)
	defer rl.SetClipboardText(original_c)
	console_view_set_input(dev, "inspect OLD Transform", len("inspect OLD Transform"))
	console.set_input_caret(dev, 8)
	console.set_input_caret(dev, 11, true)
	rl.SetClipboardText("enemy.beta-1")
	// Exercise the same clipboard entry points used by Ctrl+C, Ctrl+X, Ctrl+V.
	pasted := console.paste_clipboard(dev)
	replaced := string(dev.input[:dev.input_len]) == "inspect enemy.beta-1 Transform"
	console.set_input_caret(dev, 8)
	console.set_input_caret(dev, 20, true)
	input_copied := console.copy_selection(dev)
	input_matches := string(rl.GetClipboardText()) == "enemy.beta-1"
	input_cut := console.cut_selection(dev)
	cut_removed := string(dev.input[:dev.input_len]) == "inspect  Transform"
	cut_reinserted := console.paste_clipboard(dev) &&
		string(dev.input[:dev.input_len]) == "inspect enemy.beta-1 Transform"
	console.execute(dev, "clear")
	console.log_result(dev, `{"id":"enemy.alpha-1","name":"Alpha"}`)
	line := &dev.lines[dev.line_start]
	output_copied, output_matches := false, false
	output_cut, output_unchanged := false, false
	if line.span_count > 0 {
		console.select_output_word(dev, {line.sequence, int(line.spans[0].start) + 5})
		output_copied = console.copy_selection(dev)
		output_matches = string(rl.GetClipboardText()) == "enemy.alpha-1"
		output_cut = console.cut_selection(dev)
		output_unchanged = string(dev.input[:dev.input_len]) == "inspect enemy.beta-1 Transform"
	}
	console_view_set_input(dev, "inspect player Transform", len("inspect player Transform"))
	console.set_input_caret(dev, 8)
	console.set_input_caret(dev, 14, true)
	draft, draft_length := dev.input, dev.input_len
	draft_caret, draft_anchor := dev.input_caret, dev.input_anchor
	rl.SetClipboardText("line one\nline two")
	invalid_rejected := !console.paste_clipboard(dev)
	invalid_preserved := dev.input == draft && dev.input_len == draft_length &&
		dev.input_caret == draft_caret && dev.input_anchor == draft_anchor
	invalid_warning := &dev.lines[(dev.line_start + dev.line_count - 1) % console.Max_Log_Lines]
	warning_text := string(invalid_warning.text[:invalid_warning.len])
	invalid_warning_helpful := invalid_warning.level == .Warning &&
		strings.contains(warning_text, "256-byte") && strings.contains(warning_text, "visible line") &&
		!strings.contains(warning_text, "line one")
	oversized: [console.Max_Input_Length + 1]u8
	for &byte in oversized {byte = 'x'}
	oversized_c, _ := strings.clone_to_cstring(string(oversized[:]), context.temp_allocator)
	rl.SetClipboardText(oversized_c)
	oversized_rejected := !console.paste_clipboard(dev)
	oversized_preserved := dev.input == draft && dev.input_len == draft_length &&
		dev.input_caret == draft_caret && dev.input_anchor == draft_anchor
	oversized_warning := &dev.lines[(dev.line_start + dev.line_count - 1) % console.Max_Log_Lines]
	oversized_warning_helpful := oversized_warning.level == .Warning &&
		string(oversized_warning.text[:oversized_warning.len]) == warning_text
	rl.SetClipboardText(original_c)
	assert(pasted && replaced, "clipboard paste must replace the input selection")
	assert(input_copied && input_matches, "input selection must round-trip through the real clipboard")
	assert(input_cut && cut_removed && cut_reinserted, "input cut must copy, delete, and permit paste reinsertion")
	assert(output_copied && output_matches, "semantic output selection must round-trip through the real clipboard")
	assert(output_cut && output_unchanged, "cutting output must copy without editing the command input")
	assert(invalid_rejected && invalid_preserved && invalid_warning_helpful,
		"invalid clipboard paste must preserve draft/selection and show a generic helpful warning")
	assert(oversized_rejected && oversized_preserved && oversized_warning_helpful,
		"oversized clipboard paste must preserve draft/selection and show the same generic helpful warning")
}

console_rect_changed :: proc(before, after: rl.Image, rect: rl.Rectangle) -> bool {
	for y in max(0, int(math.ceil(rect.y))) ..< min(int(before.height), int(math.floor(rect.y + rect.height))) {
		for x in max(0, int(math.ceil(rect.x))) ..< min(int(before.width), int(math.floor(rect.x + rect.width))) {
			if rl.GetImageColor(before, i32(x), i32(y)) != rl.GetImageColor(after, i32(x), i32(y)) {return true}
		}
	}
	return false
}

console_rect_has_accent_text :: proc(image: rl.Image, rect: rl.Rectangle) -> bool {
	for y in max(0, int(math.ceil(rect.y))) ..< min(int(image.height), int(math.floor(rect.y + rect.height))) {
		for x in max(0, int(math.ceil(rect.x))) ..< min(int(image.width), int(math.floor(rect.x + rect.width))) {
			pixel := rl.GetImageColor(image, i32(x), i32(y))
			if int(pixel.g) - int(pixel.r) > 60 && pixel.g > 120 {return true}
		}
	}
	return false
}

validate_console_selection_rendering :: proc(dev: ^console.Console) {
	rl.SetWindowSize(960, 640)
	console.execute(dev, "clear")
	console.log_result(dev, `{"id":"enemy.alpha-1","name":"Alpha"}`)
	line := &dev.lines[dev.line_start]
	assert(line.span_count == 1)
	console.select_output(dev, {line.sequence, 0}, {line.sequence, 0})
	console_view_set_input(dev, "inspect enemy.beta-1 Transform", len("inspect enemy.beta-1 Transform"))
	layout := console.view_layout(f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()))
	before_input := console_snapshot(dev)
	defer rl.UnloadImage(before_input)
	console.set_input_caret(dev, 8)
	console.set_input_caret(dev, 20, true)
	input_image := console_snapshot(dev, "build/captures/console-selection-input.png")
	defer rl.UnloadImage(input_image)
	input_left := layout.input.x + 32 + console.text_width(dev, "inspect ", console.Font_Size)
	input_right := layout.input.x + 32 + console.text_width(dev, "inspect enemy.beta-1", console.Font_Size)
	assert(console_rect_changed(before_input, input_image,
		{input_left + 2, layout.input.y + 11, input_right - input_left - 4, console.Font_Size + 2}),
		"input selection background must appear within measured selected text bounds")
	assert(!console_rect_changed(before_input, input_image,
		{input_left - 4, layout.input.y + 11, 2, console.Font_Size + 2}) &&
		!console_rect_changed(before_input, input_image,
		{input_right + 3, layout.input.y + 11, 2, console.Font_Size + 2}),
		"input selection background must stop at its measured byte range")
	console.set_input_caret(dev, dev.input_len)
	before_output := console_snapshot(dev)
	defer rl.UnloadImage(before_output)
	span := line.spans[0]
	left := layout.output.x + console.text_width(dev, string(line.text[:span.start]), console.Font_Size)
	right := layout.output.x + console.text_width(dev, string(line.text[:span.end]), console.Font_Size)
	assert(console_rect_has_accent_text(before_output, {left, layout.output.y, right - left, console.Font_Size + 4}),
		"semantic entity identifiers must draw in the accent text color")
	console.select_output_word(dev, {line.sequence, int(span.start) + 5})
	output_image := console_snapshot(dev, "build/captures/console-selection-output.png")
	defer rl.UnloadImage(output_image)
	assert(console_rect_changed(before_output, output_image,
		{left + 2, layout.output.y + 1, right - left - 4, console.Font_Size + 2}),
		"output selection background must cover the semantic identifier")
	assert(!console_rect_changed(before_output, output_image,
		{left - 4, layout.output.y + 1, 2, console.Font_Size + 2}) &&
		!console_rect_changed(before_output, output_image,
		{right + 3, layout.output.y + 1, 2, console.Font_Size + 2}),
		"output selection background must stop at the semantic span's measured bounds")
}

validate_console_view :: proc() {
	assert(os.make_directory_all("build/captures") == nil || os.exists("build/captures"))
	rl.SetConfigFlags({.WINDOW_HIDDEN, .MSAA_4X_HINT})
	rl.InitWindow(960, 640, "Rune console view validation")
	defer rl.CloseWindow()
	rl.SetExitKey(rl.KeyboardKey(0))
	dev := new(console.Console)
	defer mem.free(dev)
	dev^ = console.init()
	defer console.destroy_renderer(dev)
	dev.is_open = true
	runtime_view_console = dev
	defer runtime_view_console = nil
	console.execute(dev, "clear")
	for index in 0 ..< 40 {
		console.info(dev, fmt.tprintf("%02d  Runtime output: scene objects, transforms, cameras, and command diagnostics.", index))
	}
	console.warning(dev, "A warning remains readable against the console surface.")
	console.error(dev, "An error remains readable against the console surface.")
	console_view_set_input(dev, "inspect player Transform.position", len("inspect player Transform.position"))
	wide := console_snapshot(dev, "build/captures/console-modern-wide.png")
	assert(wide.width == 960 && wide.height == 640)
	assert(console_caret_is_visible(dev, wide), "drawn caret must appear at its measured prefix position")
	rl.UnloadImage(wide)
	assert(console.text_width(dev, "WWWW", 18) > console.text_width(dev, "iiii", 18) * 1.5,
		"default console font must use proportional text measurements")
	// Verify a borrowed font uses exactly the same metrics for drawing and caret
	// placement. Replacing it never transfers ownership to the console.
	borrowed := rl.LoadFontEx("examples/assets/fonts/Inter.ttf", 64, nil, 0)
	assert(rl.IsFontValid(borrowed) && borrowed.texture.id != rl.GetFontDefault().texture.id)
	defer rl.UnloadFont(borrowed)
	rl.SetTextureFilter(borrowed.texture, .BILINEAR)
	assert(console.set_font(dev, borrowed))
	expected := rl.MeasureTextEx(borrowed, "WiWi", 18, 0).x
	assert(math.abs(console.text_width(dev, "WiWi", 18) - expected) < 0.01,
		"console text width must match its selected font")
	console_view_set_input(dev, "WiWiWi", 4)
	assert(math.abs(console.input_offset(dev, 400) - expected) < 0.01,
		"caret placement must measure its actual text prefix")
	rl.SetWindowSize(360, 540)
	long_input: [console.Max_Input_Length]u8
	for &byte in long_input {byte = 'W'}
	console_view_set_input(dev, string(long_input[:]), len(long_input))
	end_width := console.input_offset(dev, 230)
	assert(end_width > 230 && dev.renderer.input_scroll > 0,
		"long commands must scroll horizontally to keep the caret in view")
	assert(end_width - dev.renderer.input_scroll >= 0 && end_width - dev.renderer.input_scroll <= 230,
		"visible caret position must remain inside the input viewport")
	saved_scroll := dev.renderer.input_scroll
	assert(console.set_font(dev, borrowed) && dev.renderer.input_scroll == saved_scroll,
		"refreshing the same borrowed font must preserve horizontal scroll")
	preview := console.build_view(dev, 300, 10, runtime_view_measure)
	console.scroll(dev, 12, len(preview.rows), 10)
	narrow := console_snapshot(dev, "build/captures/console-modern-narrow.png")
	assert(narrow.width == 360 && narrow.height == 540)
	assert(dev.scroll_offset > 0, "narrow screenshot must show scrolled output")
	assert(console_caret_is_visible(dev, narrow), "long input caret must remain visible after resize")
	rl.UnloadImage(narrow)
	console_view_set_input(dev, string(long_input[:]), 0)
	assert(console.input_offset(dev, 230) == 0 && dev.renderer.input_scroll == 0,
		"moving to the start of a long input must reset horizontal scroll")
	assert(console.set_font(dev, {}), "empty font must restore the embedded default")
	console.ensure_renderer(dev)
	assert(dev.renderer.font.texture.id == dev.renderer.owned_font.texture.id &&
		dev.renderer.font.texture.id != borrowed.texture.id,
		"default restoration must reuse the owned font rather than retaining the borrowed atlas")
	assert(math.abs(rl.MeasureTextEx(borrowed, "WiWi", 18, 0).x - expected) < 0.01,
		"restoring the default must preserve the borrowed font's ownership")
	rl.SetWindowSize(180, 90)
	console_view_set_input(dev, string(long_input[:]), len(long_input))
	tiny := console_snapshot(dev, "build/captures/console-modern-tiny.png")
	// Desktop window decorations can impose a platform minimum width.
	assert(tiny.width == rl.GetRenderWidth() && tiny.height == rl.GetRenderHeight())
	assert(tiny.width < 250 && tiny.height == 90)
	tiny_layout := console.view_layout(f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()))
	assert(console_text_is_clipped(tiny, tiny_layout.panel),
		"text and caret must remain clipped to the panel in a tiny window")
	assert(console_caret_is_visible(dev, tiny), "tiny input viewport must keep its caret visible")
	rl.UnloadImage(tiny)
	validate_console_clipboard(dev)
	validate_console_selection_rendering(dev)
	fmt.println("Console runtime rendering and overlay screenshots passed")
}
