package main

import example_text "../shared/text"

import "core:fmt"
import "core:strings"
import rune "rune:core"
import "rune:ecs"
import "rune:replication"
import rl "vendor:raylib"

TEXT_COLOR :: rl.Color{235, 241, 250, 255}
MUTED_COLOR :: rl.Color{139, 157, 180, 255}
HOST_COLOR :: rl.Color{86, 188, 246, 255}
GUEST_COLOR :: rl.Color{255, 183, 87, 255}

draw_label :: proc(value: string, x, y, size: i32, color: rl.Color) {
	c, _ := strings.clone_to_cstring(value, context.temp_allocator)
	example_text.draw(c, x, y, size, color)
}

draw_centered_label :: proc(value: string, center_x, y, size: i32, color: rl.Color) {
	c, _ := strings.clone_to_cstring(value, context.temp_allocator)
	example_text.draw(c, center_x - example_text.measure(c, size) / 2, y, size, color)
}

draw_multiplayer :: proc(engine: ^rune.Engine, world: ^ecs.World) {
	is_host := game_state.hosting
	role := "HOST" if is_host else "GUEST"
	role_color := HOST_COLOR if is_host else GUEST_COLOR

	example_text.draw("RELAY ARENA", 40, 28, 30, TEXT_COLOR)
	example_text.draw("Two players. One shared world.", 40, 66, 16, MUTED_COLOR)
	rl.DrawRectangleRounded({792, 28, 128, 42}, .25, 6, {25, 37, 54, 255})
	draw_centered_label(role, 856, 38, 19, role_color)
	if stats_visible {draw_network_stats(&game_state)}

	example_text.draw("ROOM", 40, 104, 12, MUTED_COLOR)
	room_label := string(game_state.room_code[:]) if game_state.local_peer != 0 else "Connecting..."
	draw_label(room_label, 40, 120, 24, TEXT_COLOR)
	if game_state.local_peer == 0 {
		example_text.draw("Waiting for the relay", 340, 125, 16, MUTED_COLOR)
	} else if is_host {
		example_text.draw("Share this code to invite a friend", 340, 125, 16, MUTED_COLOR)
	} else {
		example_text.draw("Connected to the host's world", 340, 125, 16, MUTED_COLOR)
	}

	status_color := role_color
	if game_state.status == .Failed {status_color = {255, 120, 127, 255}}
	if game_state.status == .Closed {status_color = MUTED_COLOR}
	rl.DrawCircle(49, 163, 4, status_color)
	draw_label(game_state.message, 63, 153, 15, status_color)

	rl.DrawRectangleRounded({40, 180, 880, 420}, .035, 6, {18, 28, 43, 255})
	for x: i32 = 80; x < 920; x += 40 {
		rl.DrawLine(x, 182, x, 598, {29, 41, 58, 255})
	}
	for y: i32 = 220; y < 600; y += 40 {
		rl.DrawLine(42, y, 918, y, {29, 41, 58, 255})
	}
	rl.DrawRectangleLinesEx({40, 180, 880, 420}, 2, {48, 64, 86, 255})

	player_count := 0
	for entity in ecs.query2(world, replication.Identity, ecs.Transform) {
		identity, has_identity := ecs.get(world, entity, replication.Identity)
		transform, has_transform := ecs.get_transform(world, entity)
		if !has_identity || !has_transform {continue}
		player_count += 1
		position := game_render_position(&game_state, identity, {transform.position.x, transform.position.y})
		x, y := position.x, position.y
		color := HOST_COLOR if identity.owner_peer == 1 else GUEST_COLOR
		half := f32(PLAYER_SIZE) / 2
		rl.DrawRectangleRounded({x - half + 2, y - half + 5, f32(PLAYER_SIZE), f32(PLAYER_SIZE)}, .12, 4, {0, 0, 0, 70})
		rl.DrawRectangleRounded({x - half, y - half, f32(PLAYER_SIZE), f32(PLAYER_SIZE)}, .12, 4, color)
		player_role := "HOST" if identity.owner_peer == 1 else "GUEST"
		name_y := y - half - 23
		local_y := y + half + 13
		if name_y < 184 {name_y = y + half + 28}
		if local_y > 578 {
			name_y = y - half - 42
			local_y = y - half - 20
		}
		draw_centered_label(fmt.tprintf("%s  #%d", player_role, identity.id), i32(clamp(x, 110, 850)), i32(name_y), 14, color)
		if identity.owner_peer == game_state.local_peer {
			rl.DrawRectangleLinesEx({x - half - 4, y - half - 4, f32(PLAYER_SIZE) + 8, f32(PLAYER_SIZE) + 8}, 2, TEXT_COLOR)
			draw_centered_label("YOU", i32(x), i32(local_y), 12, TEXT_COLOR)
		}
	}
	if game_state.status == .Closed || game_state.status == .Failed {
		rl.DrawRectangle(240, 336, 480, 108, {13, 19, 31, 242})
		title := "ROOM CLOSED" if game_state.status == .Closed else "CONNECTION LOST"
		draw_centered_label(title, 480, 357, 24, status_color)
		draw_centered_label("Return to the menu to play again", 480, 397, 16, MUTED_COLOR)
	} else if game_state.local_peer == 0 {
		title := "Creating your room" if is_host else "Joining the room"
		draw_centered_label(title, 480, 225, 20, TEXT_COLOR)
	} else if is_host && game_state.guest_peer == 0 {
		draw_centered_label("Waiting for the other player", 480, 225, 20, TEXT_COLOR)
		draw_centered_label("You can move while they join", 480, 255, 14, MUTED_COLOR)
	} else if player_count < 2 {
		draw_centered_label("Waiting for the host's scene", 480, 225, 20, TEXT_COLOR)
	}

	controls := "WASD / ARROWS  Move your player"
	if game_state.scripted {controls = "SCRIPTED DEMO  Players move automatically"}
	draw_label(controls, 40, 615, 14, MUTED_COLOR)
	draw_label("F2  STATS", 500, 615, 12, MUTED_COLOR)
	transport := "UDP" if game_state.client.udp_ready || (game_state.client.udp_requested && game_state.client.status == .Disconnected) else ("CONNECTING UDP" if game_state.client.udp_requested else "TCP")
	draw_label(transport, 650, 615, 14, MUTED_COLOR)
	draw_label(fmt.tprintf("%d / 2 PLAYERS", player_count), 818, 615, 14, MUTED_COLOR)
}
