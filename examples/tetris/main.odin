package main

import "core:fmt"
import "core:strings"
import rune "rune:core"
import "rune:ecs"
import "rune:input"
import rl "vendor:raylib"

BOARD_W :: 10
BOARD_H :: 20
CELL :: 28
BOARD_X :: 210
BOARD_Y :: 36

Piece :: struct {
	kind: int,
	rotation: int,
	x, y: int,
}

Game :: struct {
	board: [BOARD_H][BOARD_W]u8,
	active: Piece,
	next_kind: int,
	score, lines, level: int,
	fall_timer, move_timer: f32,
	paused, game_over: bool,
}

world: ^ecs.World
game: Game
drop_audio, clear_audio: ecs.Entity

// Four rows packed into a 16-bit mask. The low nibble is the top row.
SHAPES := [7]u16{
	0x0F00, // I
	0x0660, // O
	0x0720, // T
	0x0360, // S
	0x0630, // Z
	0x0710, // J
	0x0740, // L
}

COLORS := [8]rl.Color{
	{0, 0, 0, 0},
	{53, 214, 255, 255},
	{255, 211, 64, 255},
	{184, 92, 255, 255},
	{70, 220, 120, 255},
	{255, 75, 95, 255},
	{70, 115, 255, 255},
	{255, 145, 45, 255},
}

occupied :: proc(kind, rotation, x, y: int) -> bool {
	rx, ry := x, y
	for _ in 0..<rotation {
		rx, ry = 3 - ry, rx
	}
	bit := ry * 4 + rx
	return bit >= 0 && bit < 16 && (SHAPES[kind] & (u16(1) << u16(bit))) != 0
}

collides :: proc(g: ^Game, piece: Piece) -> bool {
	for y in 0..<4 {
		for x in 0..<4 {
			if !occupied(piece.kind, piece.rotation, x, y) { continue }
			bx, by := piece.x + x, piece.y + y
			if bx < 0 || bx >= BOARD_W || by >= BOARD_H { return true }
			if by >= 0 && g.board[by][bx] != 0 { return true }
		}
	}
	return false
}

random_kind :: proc() -> int { return int(rl.GetRandomValue(0, 6)) }

spawn_piece :: proc(g: ^Game) {
	g.active = {kind = g.next_kind, x = 3, y = -1}
	g.next_kind = random_kind()
	if collides(g, g.active) { g.game_over = true }
}

reset_game :: proc(g: ^Game) {
	g^ = {}
	g.level = 1
	g.next_kind = random_kind()
	spawn_piece(g)
}

clear_lines :: proc(g: ^Game) -> int {
	cleared: int
	y := BOARD_H - 1
	for y >= 0 {
		full := true
		for x in 0..<BOARD_W {
			if g.board[y][x] == 0 { full = false; break }
		}
		if !full { y -= 1; continue }
		for pull := y; pull > 0; pull -= 1 { g.board[pull] = g.board[pull - 1] }
		g.board[0] = {}
		cleared += 1
	}
	if cleared > 0 {
		points := [5]int{0, 100, 300, 500, 800}
		g.score += points[cleared] * g.level
		g.lines += cleared
		g.level = g.lines / 10 + 1
	}
	return cleared
}

lock_piece :: proc(g: ^Game, engine: ^rune.Engine) {
	for y in 0..<4 {
		for x in 0..<4 {
			if !occupied(g.active.kind, g.active.rotation, x, y) { continue }
			bx, by := g.active.x + x, g.active.y + y
			if by < 0 { g.game_over = true; continue }
			g.board[by][bx] = u8(g.active.kind + 1)
		}
	}
	if g.game_over { return }
	rune.play_audio(engine, world, drop_audio, "default")
	if clear_lines(g) > 0 { rune.play_audio(engine, world, clear_audio, "default") }
	spawn_piece(g)
}

move_piece :: proc(g: ^Game, dx, dy: int) -> bool {
	candidate := g.active
	candidate.x += dx
	candidate.y += dy
	if collides(g, candidate) { return false }
	g.active = candidate
	return true
}

rotate_piece :: proc(g: ^Game, direction: int) {
	candidate := g.active
	candidate.rotation = (candidate.rotation + direction + 4) % 4
	kicks := [5]int{0, -1, 1, -2, 2}
	for kick in kicks {
		candidate.x = g.active.x + kick
		if !collides(g, candidate) { g.active = candidate; return }
	}
}

hard_drop :: proc(g: ^Game, engine: ^rune.Engine) {
	distance: int
	for move_piece(g, 0, 1) { distance += 1 }
	g.score += distance * 2
	lock_piece(g, engine)
}

update_tetris :: proc(engine: ^rune.Engine, scene_world: ^ecs.World) {
	controls := rune.input_state(engine)
	if input.pressed(controls, "restart") { reset_game(&game); return }
	if input.pressed(controls, "pause") && !game.game_over { game.paused = !game.paused }
	if game.paused || game.game_over { return }

	if input.pressed(controls, "rotate_cw") { rotate_piece(&game, 1) }
	if input.pressed(controls, "rotate_ccw") { rotate_piece(&game, -1) }
	if input.pressed(controls, "hard_drop") { hard_drop(&game, engine); return }

	direction: int
	if input.pressed(controls, "move_left") { direction = -1 }
	if input.pressed(controls, "move_right") { direction = 1 }
	if direction != 0 {
		move_piece(&game, direction, 0)
		game.move_timer = .16
	} else if input.is_down(controls, "move_left") || input.is_down(controls, "move_right") {
		game.move_timer -= engine.delta_time
		if game.move_timer <= 0 {
			if input.is_down(controls, "move_left") { direction = -1 } else { direction = 1 }
			move_piece(&game, direction, 0)
			game.move_timer = .055
		}
	} else {
		game.move_timer = 0
	}

	interval := max(.07, .72 - f32(game.level - 1) * .055)
	if input.is_down(controls, "soft_drop") { interval = .035 }
	game.fall_timer += engine.delta_time
	if game.fall_timer >= interval {
		game.fall_timer = 0
		if !move_piece(&game, 0, 1) { lock_piece(&game, engine) }
		else if input.is_down(controls, "soft_drop") { game.score += 1 }
	}
}

draw_cell :: proc(x, y: int, tint: rl.Color, ghost := false) {
	rect := rl.Rectangle{f32(x + 1), f32(y + 1), f32(CELL - 2), f32(CELL - 2)}
	if ghost {
		ghost_tint := tint
		ghost_tint.a = 55
		rl.DrawRectangleLinesEx(rect, 2, ghost_tint)
	} else {
		rl.DrawRectangleRec(rect, tint)
		shine := tint
		shine.r = u8(min(i32(shine.r) + 45, 255))
		shine.g = u8(min(i32(shine.g) + 45, 255))
		shine.b = u8(min(i32(shine.b) + 45, 255))
		rl.DrawRectangle(i32(x + 3), i32(y + 3), i32(CELL - 6), 3, shine)
	}
}

draw_piece :: proc(piece: Piece, origin_x, origin_y: int, ghost := false) {
	for y in 0..<4 {
		for x in 0..<4 {
			if occupied(piece.kind, piece.rotation, x, y) && piece.y + y >= 0 {
				draw_cell(origin_x + (piece.x + x) * CELL, origin_y + (piece.y + y) * CELL, COLORS[piece.kind + 1], ghost)
			}
		}
	}
}

draw_value :: proc(label: cstring, value: int, x, y: i32) {
	rl.DrawText(label, x, y, 16, {128, 145, 175, 255})
	text := fmt.tprintf("%d", value)
	c_text, _ := strings.clone_to_cstring(text, context.temp_allocator)
	rl.DrawText(c_text, x, y + 22, 28, rl.RAYWHITE)
}

draw_tetris :: proc(engine: ^rune.Engine, scene_world: ^ecs.World) {

	rl.DrawText("RUNE BLOCKS", 34, 40, 22, {53, 214, 255, 255})

	draw_value("SCORE", game.score, 42, 135)
	draw_value("LINES", game.lines, 42, 215)
	draw_value("LEVEL", game.level, 42, 295)

	rl.DrawRectangle(BOARD_X - 5, BOARD_Y - 5, BOARD_W * CELL + 10, BOARD_H * CELL + 10, {30, 40, 65, 255})
	rl.DrawRectangle(BOARD_X, BOARD_Y, BOARD_W * CELL, BOARD_H * CELL, {10, 15, 29, 255})
	for y in 0..<BOARD_H {
		for x in 0..<BOARD_W {
			rl.DrawRectangleLines(i32(BOARD_X + x * CELL), i32(BOARD_Y + y * CELL), i32(CELL), i32(CELL), {24, 34, 55, 255})
			if game.board[y][x] != 0 { draw_cell(BOARD_X + x * CELL, BOARD_Y + y * CELL, COLORS[game.board[y][x]]) }
		}
	}

	ghost := game.active
	for {
		next := ghost
		next.y += 1
		if collides(&game, next) { break }
		ghost = next
	}
	draw_piece(ghost, BOARD_X, BOARD_Y, true)
	draw_piece(game.active, BOARD_X, BOARD_Y)

	panel_x := BOARD_X + BOARD_W * CELL + 38
	rl.DrawText("NEXT", i32(panel_x), 48, 18, {128, 145, 175, 255})
	rl.DrawRectangleLines(i32(panel_x), 76, 136, 118, {45, 59, 88, 255})
	preview := Piece{kind = game.next_kind, x = 0, y = 0}
	for y in 0..<4 {
		for x in 0..<4 {
			if occupied(preview.kind, 0, x, y) {
				draw_cell(panel_x + 12 + x * 24, 88 + y * 24, COLORS[preview.kind + 1])
			}
		}
	}
	rl.DrawText("CONTROLS", i32(panel_x), 235, 18, {128, 145, 175, 255})
	rl.DrawText("LEFT/RIGHT  MOVE", i32(panel_x), 270, 14, rl.LIGHTGRAY)
	rl.DrawText("DOWN        SOFT DROP", i32(panel_x), 296, 14, rl.LIGHTGRAY)
	rl.DrawText("SPACE       HARD DROP", i32(panel_x), 322, 14, rl.LIGHTGRAY)
	rl.DrawText("UP / Z      ROTATE", i32(panel_x), 348, 14, rl.LIGHTGRAY)
	rl.DrawText("P           PAUSE", i32(panel_x), 374, 14, rl.LIGHTGRAY)
	rl.DrawText("R           RESTART", i32(panel_x), 400, 14, rl.LIGHTGRAY)

	if game.paused || game.game_over {
		rl.DrawRectangle(BOARD_X, BOARD_Y + 225, BOARD_W * CELL, 110, {5, 8, 18, 235})
		title: cstring = "PAUSED"
		subtitle: cstring = "P TO CONTINUE"
		if game.game_over { title, subtitle = "GAME OVER", "R TO RESTART" }
		title_w := rl.MeasureText(title, 30)
		subtitle_w := rl.MeasureText(subtitle, 16)
		rl.DrawText(title, BOARD_X + (BOARD_W * CELL - title_w) / 2, BOARD_Y + 245, 30, rl.RAYWHITE)
		rl.DrawText(subtitle, BOARD_X + (BOARD_W * CELL - subtitle_w) / 2, BOARD_Y + 288, 16, {128, 145, 175, 255})
	}
}

initialize_tetris :: proc(engine: ^rune.Engine, scene_world: ^ecs.World) {
	world = scene_world
	drop_audio, _ = ecs.find_entity_by_id(scene_world, "drop_audio")
	clear_audio, _ = ecs.find_entity_by_id(scene_world, "clear_audio")
	reset_game(&game)
}

main :: proc() {
	engine, ok := rune.init("examples/tetris/project.json")
	if !ok { fmt.eprintln("Could not load examples/tetris/project.json"); return }
	defer rune.shutdown(&engine)

	if !rune.register_system(&engine, {name = "tetris", start = initialize_tetris, update = update_tetris, draw = draw_tetris, on_scene_reloaded = initialize_tetris}) {
		fmt.eprintln("Could not register Tetris system")
		return
	}
	if !rune.run(&engine) { fmt.eprintln("Could not run startup scene: ", rune.last_scene_error()) }
}
