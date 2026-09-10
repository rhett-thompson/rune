package main

import example_text "../shared/text"

import "core:fmt"
import "core:math"
import "rune:audio"
import "rune:console"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import "rune:ui"
import rl "vendor:raylib"

interface: ui.Context
menu_open := true
volume: f32 = 0.65
elapsed: f32

start :: proc(game: ^rune.Engine, world: ^ecs.World) {
	assert(ui.init(&interface, example_text.font()))
	rl.SetExitKey(rl.KeyboardKey(0))
	audio.set_bus_volume(&game.audio.mixer, .master, volume)
	menu_open = true
	rune.set_paused(game, true)
}

shutdown :: proc(game: ^rune.Engine, world: ^ecs.World) { ui.destroy(&interface) }

ui_update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	if rl.IsKeyPressed(.F11) { rune.toggle_borderless(game) }
	ui.set_font(&interface, example_text.font())
	controls := ui.read_input(rune.input_state(game))
	controls.blocked = console.is_open(rune.developer_console(game))
	was_open := menu_open
	if controls.cancel && !controls.blocked {
		menu_open = !menu_open
		ui.reset_focus(&interface)
	}
	if was_open || menu_open || controls.blocked { input.capture(rune.input_state(game)) }
	rune.set_paused(game, menu_open)
	dimensions := [2]f32{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
	if !ui.begin(&interface, dimensions, controls, game.frame_delta_time) { return }
	ui.panel(
		&interface,
		"screen",
		{
			layout = {
				sizing = {width = ui.grow({}), height = ui.grow({})},
				padding = ui.padding(24),
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = {9, 14, 24, 165} if menu_open else {},
		},
	)
	if menu_open {
		ui.panel(
			&interface,
			"menu",
			{
				layout = {
					sizing = {width = ui.grow({max = 420}), height = ui.fit({})},
					layoutDirection = .TopToBottom,
					padding = ui.padding(28),
					childGap = 20,
				},
				backgroundColor = {20, 29, 44, 250},
				cornerRadius = ui.corners(12),
				border = {color = {48, 66, 88, 255}, width = {left = 1, right = 1, top = 1, bottom = 1}},
			},
		)
		ui.label(&interface, "Paused", interface.style.text, 38)
		if ui.button(&interface, "resume", "Resume game") { menu_open = false }
		ui.label(&interface, fmt.tprintf("Master volume  %d%%", i32(volume * 100 + 0.5)), interface.style.text, 18)
		if ui.slider(&interface, "volume", &volume, 0, 1) { audio.set_bus_volume(&game.audio.mixer, .master, volume) }
		if ui.button(&interface, "quit", "Quit") { rune.request_exit(game) }
		ui.label(&interface, "UP / DOWN  Navigate\nLEFT / RIGHT  Adjust     ENTER  Select", interface.style.muted, 14)
		ui.end_panel(&interface)
	} else {
		ui.panel(
			&interface,
			"hint",
			{
				layout = {sizing = {width = ui.fit({}), height = ui.fit({})}, padding = ui.padding(18)},
				floating = {
					attachTo = .Root,
					attachment = {element = .CenterBottom, parent = .CenterBottom},
					offset = {0, -24},
				},
				backgroundColor = {20, 29, 44, 230},
				cornerRadius = ui.corners(8),
			},
		)
		ui.label(&interface, "ESC / gamepad B  Pause     A / D  Move", interface.style.text, 18)
		ui.end_panel(&interface)
	}
	ui.end_panel(&interface)
	if !ui.finish(&interface) { console.error(rune.developer_console(game), ui.last_error(&interface)) }
	rune.set_paused(game, menu_open)
}

update :: proc(game: ^rune.Engine, world: ^ecs.World) {
	elapsed += game.delta_time
	entity, _ := ecs.find_entity_by_id(world, "orb")
	transform, _ := ecs.get_transform(world, entity)
	transform.position[0] += input.axis(rune.input_state(game), "move") * 180 * game.delta_time
	transform.position[1] = 230 + math.sin(elapsed) * 70
	ecs.set_transform(world, entity, transform)
}

background :: proc(game: ^rune.Engine, world: ^ecs.World) {
	width, height := rl.GetScreenWidth(), rl.GetScreenHeight()
	for x: i32 = 0; x < width; x += 48 { rl.DrawLine(x, 0, x, height, {26, 37, 53, 255}) }
	for y: i32 = 0; y < height; y += 48 { rl.DrawLine(0, y, width, y, {26, 37, 53, 255}) }
	entity, _ := ecs.find_entity_by_id(world, "orb")
	transform, _ := ecs.get_transform(world, entity)
	rl.DrawCircleV({transform.position[0], transform.position[1]}, 32, {93, 225, 189, 255})
	rl.DrawCircleLines(i32(transform.position[0]), i32(transform.position[1]), 46, {57, 126, 121, 255})
}

draw :: proc(game: ^rune.Engine, world: ^ecs.World) {
	ui.draw(&interface)
}

ui_status :: proc(dev: ^console.Console, arguments: string) {
	focus :=
		"resume" if ui.focused(&interface, "resume") else "volume" if ui.focused(&interface, "volume") else "quit" if ui.focused(&interface, "quit") else ""
	console.set_result(dev, struct {
		open:         bool,
		volume:       f32,
		focus:        string,
		layout_error: string,
	}{menu_open, volume, focus, ui.last_error(&interface)})
}

main :: proc() {
	game, ok := rune.init("examples/clay_ui/project.json")
	if !ok { fmt.eprintln("Could not initialize Clay UI example"); return }
	defer rune.shutdown(&game)
	if !example_text.init(&game.assets) { fmt.eprintln("Could not load shared example font"); return }
	console.register(rune.developer_console(&game), "ui_status", "Read menu, focus and volume state.", ui_status)
	if !rune.register_system(
		&game,
		{
			name = "clay_menu",
			start = start,
			ui_update = ui_update,
			update = update,
			pre_draw = background,
			draw_ui = draw,
			shutdown = shutdown,
		},
	) { return }
	if !rune.run(&game) {
		fmt.eprintln(rune.last_scene_error())
	}
}
