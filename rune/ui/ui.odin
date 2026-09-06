// Optional, code-first game UI. Clay owns layout; Rune owns input/focus and
// rendering. Build in ui_update, draw in draw. Context must stay at one address.
package ui

import "base:runtime"
import "core:math"
import "core:mem"
import "core:strings"
import clay "../../third_party/clay/clay-odin"
import rl "vendor:raylib"

Element :: clay.ElementDeclaration
Color :: clay.Color
grow :: clay.SizingGrow
fit :: clay.SizingFit
fixed :: clay.SizingFixed
percent :: clay.SizingPercent
padding :: clay.PaddingAll
corners :: clay.CornerRadiusAll

Inputs :: struct {
	pointer: [2]f32,
	pointer_down: bool,
	scroll: [2]f32,
	next, previous, activate, cancel, left, right: bool,
	blocked: bool,
}

Style :: struct {
	text, muted, surface, hover, pressed, accent, disabled: Color,
	font_size: u16,
	height, radius: f32,
}

default_style :: proc() -> Style {
	return {
		text = {235, 241, 250, 255}, muted = {147, 163, 188, 255},
		surface = {34, 45, 64, 255}, hover = {47, 64, 87, 255},
		pressed = {23, 111, 109, 255}, accent = {93, 225, 189, 255},
		disabled = {65, 72, 86, 255}, font_size = 20, height = 46, radius = 6,
	}
}

// Optional override for headless layout tests or custom text measurement.
Measure_Proc :: #type proc(text: string, font_size, spacing: f32) -> [2]f32

@(private)
active_context: ^Context

Context :: struct {
	style: Style,
	font: rl.Font, // Borrowed. The caller/asset manager owns it.
	measure: Measure_Proc,
	native: ^clay.Context,
	native_memory: rawptr,
	allocator: mem.Allocator,
	scratch: mem.Dynamic_Arena,
	commands: clay.ClayArray(clay.RenderCommand),
	previous_context: ^clay.Context,
	widgets, previous_widgets: [dynamic]u32,
	focus_id, active_id, clicked_id, hovered_id: u32,
	inputs: Inputs,
	last_pointer: [2]f32,
	last_down: bool,
	building, ready: bool,
	depth: int,
	error_buffer: [256]u8,
	error_length: int,
}

// Initialize after the raylib window exists, or supply a custom measure proc
// for headless use. Destroy before the window closes. Do not copy Context.
init :: proc(ui: ^Context, font := rl.Font{}, measure: Measure_Proc = nil) -> bool {
	if ui == nil || ui.native != nil {return false}
	selected := font
	if measure == nil && selected.baseSize <= 0 {
		if !rl.IsWindowReady() {return false}
		selected = rl.GetFontDefault()
	}
	ui.allocator = context.allocator
	ui.font, ui.measure, ui.style = selected, measure, default_style()
	mem.dynamic_arena_init(&ui.scratch)
	ui.widgets = make([dynamic]u32, 0, 16)
	ui.previous_widgets = make([dynamic]u32, 0, 16)
	previous := clay.GetCurrentContext()
	defer clay.SetCurrentContext(previous)
	size := clay.MinMemorySize()
	memory, err := mem.alloc(int(size), 64, ui.allocator)
	if err != nil {destroy(ui); return false}
	ui.native_memory = memory
	ui.native = clay.Initialize(clay.CreateArenaWithCapacityAndMemory(uint(size), ([^]u8)(memory)),
		{1, 1}, {handler = on_error, userData = ui})
	if ui.native == nil || ui.error_length > 0 {destroy(ui); return false}
	clay.SetMeasureTextFunction(measure_text, ui)
	return true
}

destroy :: proc(ui: ^Context) {
	if ui == nil {return}
	if ui.building {finish(ui)}
	if ui.native != nil && clay.GetCurrentContext() == ui.native {clay.SetCurrentContext(nil)}
	if ui.native_memory != nil {mem.free(ui.native_memory, ui.allocator)}
	delete(ui.widgets)
	delete(ui.previous_widgets)
	mem.dynamic_arena_destroy(&ui.scratch)
	ui^ = {}
}

last_error :: proc(ui: ^Context) -> string {return string(ui.error_buffer[:ui.error_length])}

// Call after refreshing an asset-backed font, before begin. Clay caches text
// measurements, so changing the borrowed font also clears that cache.
set_font :: proc(ui: ^Context, font: rl.Font) -> bool {
	if ui.native == nil || ui.building || font.baseSize <= 0 {return false}
	if ui.font.texture.id == font.texture.id && ui.font.glyphs == font.glyphs {return true}
	ui.font = font
	previous := clay.GetCurrentContext()
	clay.SetCurrentContext(ui.native)
	clay.ResetMeasureTextCache()
	clay.SetCurrentContext(previous)
	return true
}

begin :: proc(ui: ^Context, dimensions: [2]f32, inputs: Inputs, dt: f32) -> bool {
	if ui.native == nil || active_context != nil || ui.building || dimensions[0] <= 0 || dimensions[1] <= 0 ||
	   math.is_nan(dimensions[0]) || math.is_inf(dimensions[0]) ||
	   math.is_nan(dimensions[1]) || math.is_inf(dimensions[1]) {return false}
	ui.previous_context = clay.GetCurrentContext()
	clay.SetCurrentContext(ui.native)
	ui.ready = false
	ui.error_length = 0
	ui.inputs = inputs
	clay.SetLayoutDimensions({dimensions[0], dimensions[1]})
	clay.SetPointerState(inputs.pointer, inputs.pointer_down && !inputs.blocked)
	clay.UpdateScrollContainers(false, inputs.scroll if !inputs.blocked else {},
		clamp(dt, 0, 0.1) if !math.is_nan(dt) else 0)
	ui.hovered_id, ui.clicked_id = 0, 0
	if !inputs.blocked {
		for id in ui.previous_widgets {if clay.PointerOver({id = id}) {ui.hovered_id = id}}
		if inputs.pointer != ui.last_pointer && ui.hovered_id != 0 {ui.focus_id = ui.hovered_id}
		if inputs.pointer_down && !ui.last_down {
			ui.active_id = ui.hovered_id
			if ui.hovered_id != 0 {ui.focus_id = ui.hovered_id}
		}
		if !inputs.pointer_down && ui.last_down {
			if ui.active_id == ui.hovered_id {ui.clicked_id = ui.active_id}
			ui.active_id = 0
		}
		if inputs.next != inputs.previous && len(ui.previous_widgets) > 0 {
			index := -1
			for id, i in ui.previous_widgets {if id == ui.focus_id {index = i; break}}
			if inputs.next {index += 1} else {index = len(ui.previous_widgets) - 1 if index < 0 else index - 1}
			index = (index + len(ui.previous_widgets)) % len(ui.previous_widgets)
			ui.focus_id = ui.previous_widgets[index]
		}
	} else {ui.active_id = 0}
	ui.last_pointer, ui.last_down = inputs.pointer, inputs.pointer_down
	mem.dynamic_arena_reset(&ui.scratch)
	resize(&ui.widgets, 0)
	ui.building = true
	active_context = ui
	ui.depth = 0
	clay.BeginLayout()
	return true
}

// End layout before any draw call. Render commands and text survive until the
// next begin. Unbalanced panels fail with a diagnostic rather than leaking scope.
finish :: proc(ui: ^Context) -> bool {
	if !ui.building {return false}
	if ui.depth != 0 {record_error(ui, "Unbalanced ui.panel / ui.end_panel")}
	for ui.depth > 0 {clay._CloseElement(); ui.depth -= 1}
	ui.commands = clay.EndLayout()
	ui.building = false
	active_context = nil
	clay.SetCurrentContext(ui.previous_context)
	found := false
	for id in ui.widgets {if id == ui.focus_id {found = true; break}}
	if !found {ui.focus_id = ui.widgets[0] if len(ui.widgets) > 0 else 0}
	found = false
	for id in ui.widgets {if id == ui.active_id {found = true; break}}
	if !found {ui.active_id = 0}
	ui.widgets, ui.previous_widgets = ui.previous_widgets, ui.widgets
	ui.ready = ui.error_length == 0
	return ui.ready
}

panel :: proc(ui: ^Context, id: string, declaration: Element) {
	assert(ui.building)
	config := declaration
	config.id = clay.ID(copy_text(ui, id))
	clay._OpenElement()
	clay.ConfigureOpenElement(config)
	ui.depth += 1
}

end_panel :: proc(ui: ^Context) {
	assert(ui.building)
	if ui.depth <= 0 {record_error(ui, "ui.end_panel without ui.panel"); return}
	clay._CloseElement()
	ui.depth -= 1
}

// Open a clipped panel using Clay's persisted scroll position. Close it with
// end_panel. Mouse-wheel deltas supplied to begin update the previous layout.
scroll_panel :: proc(ui: ^Context, id: string, declaration: Element,
	horizontal: bool = false, vertical: bool = true) {
	assert(ui.building)
	config := declaration
	config.clip.horizontal, config.clip.vertical = horizontal, vertical
	data := clay.GetScrollContainerData(clay.ID(id))
	if data.found {config.clip.childOffset = data.scrollPosition^}
	panel(ui, id, config)
}

label :: proc(ui: ^Context, text: string, color: Color, size: u16 = 0) {
	assert(ui.building)
	clay.TextDynamic(copy_text(ui, text), clay.TextConfig({textColor = color,
		fontSize = size if size > 0 else ui.style.font_size, wrapMode = .Words}))
}

button :: proc(ui: ^Context, id, text: string, enabled: bool = true) -> bool {
	key := widget(ui, id, enabled)
	background := ui.style.surface
	if !enabled {background = ui.style.disabled}
	else if !ui.inputs.blocked {
		if key == ui.hovered_id || key == ui.focus_id {background = ui.style.hover}
		if key == ui.active_id {background = ui.style.pressed}
	}
	panel(ui, id, {layout = {sizing = {width = grow({}), height = fixed(ui.style.height)},
		childAlignment = {x = .Center, y = .Center}, padding = padding(10)},
		backgroundColor = background, cornerRadius = corners(ui.style.radius),
		border = {color = ui.style.accent, width = clay.BorderOutside(2 if enabled && key == ui.focus_id && !ui.inputs.blocked else 0)}})
	label(ui, text, ui.style.text)
	end_panel(ui)
	return enabled && !ui.inputs.blocked && (ui.clicked_id == key || (ui.inputs.activate && ui.focus_id == key))
}

// A normalized bar slider. Pointer drag or left/right changes value; navigation
// focuses it in declaration order. Returns true only when the value changes.
slider :: proc(ui: ^Context, id: string, value: ^f32, minimum, maximum: f32,
	step: f32 = 0.05, enabled: bool = true) -> bool {
	assert(ui.building)
	if value == nil || !(maximum > minimum) || math.is_inf(minimum) || math.is_inf(maximum) ||
	   !(step > 0) || math.is_inf(step) || math.is_nan(value^) || math.is_inf(value^) {return false}
	key := widget(ui, id, enabled)
	before := value^
	if enabled && !ui.inputs.blocked {
		if ui.focus_id == key {
			if ui.inputs.right {value^ += step}
			if ui.inputs.left {value^ -= step}
		}
		if ui.active_id == key || ui.clicked_id == key {
			bounds := clay.GetElementData({id = key})
			if bounds.found && bounds.boundingBox.width > 0 {
				t := clamp((ui.inputs.pointer[0] - bounds.boundingBox.x) / bounds.boundingBox.width, 0, 1)
				value^ = minimum + t * (maximum - minimum)
			}
		}
	}
	value^ = clamp(value^, minimum, maximum)
	t := clamp((value^ - minimum) / (maximum - minimum), 0, 1)
	panel(ui, id, {layout = {sizing = {width = grow({}), height = fixed(24)}},
		backgroundColor = ui.style.surface, cornerRadius = corners(4),
		border = {color = ui.style.accent, width = clay.BorderOutside(2 if enabled && ui.focus_id == key && !ui.inputs.blocked else 0)}})
	clay._OpenElement()
	clay.ConfigureOpenElement({layout = {sizing = {width = percent(t), height = grow({})}},
		backgroundColor = ui.style.accent if enabled else ui.style.disabled, cornerRadius = corners(4)})
	clay._CloseElement()
	end_panel(ui)
	return before != value^
}

image :: proc(ui: ^Context, id: string, texture: rl.Texture2D, size: [2]f32, tint: Color = {255,255,255,255}) {
	assert(ui.building)
	stored, _ := mem.new(rl.Texture2D, mem.dynamic_arena_allocator(&ui.scratch))
	stored^ = texture
	panel(ui, id, {layout = {sizing = {width = fixed(size[0]), height = fixed(size[1])}},
		image = {imageData = stored}, backgroundColor = tint})
	end_panel(ui)
}

focused :: proc(ui: ^Context, id: string) -> bool {return ui.focus_id == clay.ID(id).id}

reset_focus :: proc(ui: ^Context) {ui.focus_id, ui.active_id = 0, 0}

// Bounds from the most recently completed layout, useful for tool inspection.
bounds :: proc(ui: ^Context, id: string) -> (rl.Rectangle, bool) {
	if ui.native == nil || ui.building {return {}, false}
	previous := clay.GetCurrentContext()
	clay.SetCurrentContext(ui.native)
	data := clay.GetElementData(clay.ID(id))
	clay.SetCurrentContext(previous)
	b := data.boundingBox
	return {b.x,b.y,b.width,b.height}, data.found
}

@(private)
widget :: proc(ui: ^Context, id: string, enabled: bool) -> u32 {
	assert(ui.building)
	key := clay.ID(id).id
	if enabled {
		append(&ui.widgets, key)
		if ui.focus_id == 0 {ui.focus_id = key}
	}
	return key
}

@(private)
copy_text :: proc(ui: ^Context, text: string) -> string {
	result, _ := strings.clone(text, mem.dynamic_arena_allocator(&ui.scratch))
	return result
}

@(private)
record_error :: proc(ui: ^Context, text: string) {
	ui.error_length = copy(ui.error_buffer[:], transmute([]u8)text)
}

@(private)
on_error :: proc "c" (error: clay.ErrorData) {
	context = runtime.default_context()
	ui := (^Context)(error.userData)
	if ui != nil {record_error(ui, string(error.errorText.chars[:error.errorText.length]))}
}

@(private)
measure_text :: proc "c" (text: clay.StringSlice, config: ^clay.TextElementConfig, user: rawptr) -> clay.Dimensions {
	context = runtime.default_context()
	ui := (^Context)(user)
	value := string(text.chars[:text.length])
	if ui.measure != nil {
		size := ui.measure(value, f32(config.fontSize), f32(config.letterSpacing))
		return {size[0], size[1]}
	}
	value_c, _ := strings.clone_to_cstring(value, mem.dynamic_arena_allocator(&ui.scratch))
	size := rl.MeasureTextEx(ui.font, value_c, f32(config.fontSize), f32(config.letterSpacing))
	return {size[0], size[1]}
}
