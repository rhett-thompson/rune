package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import rune "rune:core"
import "rune:assets"
import "rune:ecs"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

MAP :: 31
MAX_ENEMIES :: 32
FOV :: f32(math.PI / 3)

Dungeon_Generator :: struct {
	map_size: i32,
	starting_enemies: i32,
	enemies_per_level: i32,
	room_count: i32,
	wall_height: f32,
}

Dungeon_Presentation :: struct {
	wall_textures: [4]string,
	enemy_textures: [3]string,
	weapon_texture: string,
}

Dungeon_Player :: struct {
	health: i32,
	walk_speed: f32,
	sprint_speed: f32,
	attack_range: f32,
	attack_damage: i32,
}

Enemy :: struct {
	x, y: f32,
	hp: i32,
	cooldown: f32,
	alive: bool,
	kind: i32,
}

Dungeon :: struct {
	tiles: [MAP][MAP]u8,
	x, y, angle: f32,
	health, level, kills: i32,
	attack, hurt, step: f32,
	enemies: [MAX_ENEMIES]Enemy,
	enemy_count: i32,
	walls: [4]rl.Texture2D,
	monsters: [3]rl.Texture2D,
	weapon: rl.Texture2D,
}

game: Dungeon
generator: Dungeon_Generator
presentation: Dungeon_Presentation
player_settings: Dungeon_Player
player_entity: ecs.Entity
hit_audio, swing_audio, death_audio, footstep_audio, level_audio: ecs.Entity

get_texture :: proc(engine: ^rune.Engine, path: string) -> rl.Texture2D {
	value, _ := assets.texture(&engine.assets, path)
	rl.SetTextureFilter(value, .POINT)
	return value
}

component_into :: proc(world: ^ecs.World, name: string, result: ^$T) -> bool {
	entities := ecs.entities_with_component(world, name)
	if len(entities) != 1 { return false }
	value, found := ecs.get_component(world, entities[0], name)
	if !found { return false }
	data, err := json.marshal(value)
	if err != nil { return false }
	defer delete(data)
	return json.unmarshal(data, result) == nil
}

load_assets :: proc(engine: ^rune.Engine) {
	game.walls = {
		get_texture(engine, presentation.wall_textures[0]),
		get_texture(engine, presentation.wall_textures[1]),
		get_texture(engine, presentation.wall_textures[2]),
		get_texture(engine, presentation.wall_textures[3]),
	}
	game.monsters = {
		get_texture(engine, presentation.enemy_textures[0]),
		get_texture(engine, presentation.enemy_textures[1]),
		get_texture(engine, presentation.enemy_textures[2]),
	}
	game.weapon = get_texture(engine, presentation.weapon_texture)
}

initialize_dungeon :: proc(engine: ^rune.Engine, world: ^ecs.World) -> bool {
	ok: bool
	player_entity, ok = ecs.find_entity_by_id(world, "player"); if !ok { return false }
	hit_audio, ok = ecs.find_entity_by_id(world, "hit_audio"); if !ok { return false }
	swing_audio, ok = ecs.find_entity_by_id(world, "swing_audio"); if !ok { return false }
	death_audio, ok = ecs.find_entity_by_id(world, "death_audio"); if !ok { return false }
	footstep_audio, ok = ecs.find_entity_by_id(world, "footstep_audio"); if !ok { return false }
	level_audio, ok = ecs.find_entity_by_id(world, "level_audio"); if !ok { return false }
	if !component_into(world, "DungeonGenerator", &generator) ||
	   !component_into(world, "DungeonPresentation", &presentation) ||
	   !component_into(world, "DungeonPlayer", &player_settings) {
		return false
	}
	load_assets(engine)
	reset_game(true)
	return true
}

dungeon_reload_system :: proc(engine: ^rune.Engine, world: ^ecs.World) {
	initialize_dungeon(engine, world)
}

play_audio :: proc(engine: ^rune.Engine, world: ^ecs.World, entity: ecs.Entity) {
	rune.play_audio(engine, world, entity)
}

open :: proc(x, y: f32) -> bool {
	r: f32 = .22
	if x < 1 || y < 1 || x >= MAP - 1 || y >= MAP - 1 { return false }
	return game.tiles[i32(y-r)][i32(x-r)] == 0 &&
		game.tiles[i32(y-r)][i32(x+r)] == 0 &&
		game.tiles[i32(y+r)][i32(x-r)] == 0 &&
		game.tiles[i32(y+r)][i32(x+r)] == 0
}

generate :: proc() {
	for y in 0..<MAP { for x in 0..<MAP { game.tiles[y][x] = 1 } }
	stack: [MAP*MAP][2]i32
	count := 1
	stack[0] = {1, 1}
	game.tiles[1][1] = 0
	dirs := [4][2]i32{{2,0},{-2,0},{0,2},{0,-2}}
	for count > 0 {
		at := stack[count-1]
		options: [4][2]i32
		n := 0
		for d in dirs {
			x, y := at[0]+d[0], at[1]+d[1]
			if x > 0 && y > 0 && x < MAP-1 && y < MAP-1 && game.tiles[y][x] != 0 {
				options[n] = {x,y}; n += 1
			}
		}
		if n == 0 { count -= 1; continue }
		next := options[rl.GetRandomValue(0, i32(n-1))]
		game.tiles[(at[1]+next[1])/2][(at[0]+next[0])/2] = 0
		game.tiles[next[1]][next[0]] = 0
		stack[count] = next; count += 1
	}
	for _ in 0..<36 {
		x, y := rl.GetRandomValue(2, MAP-3), rl.GetRandomValue(2, MAP-3)
		game.tiles[y][x] = 0
	}
	for _ in 0..<max(1, generator.room_count) {
		cx, cy := rl.GetRandomValue(3, MAP-4), rl.GetRandomValue(3, MAP-4)
		for y in cy-1..=cy+1 { for x in cx-1..=cx+1 { game.tiles[y][x] = 0 } }
	}
	for y in 1..=3 { for x in 1..=3 { game.tiles[y][x] = 0 } }
}

visible :: proc(x1,y1,x2,y2: f32) -> bool {
	dx,dy := x2-x1,y2-y1
	d := f32(math.sqrt(f64(dx*dx+dy*dy)))
	steps := max(1,i32(d*12))
	for i in 1..<steps {
		t := f32(i)/f32(steps)
		if game.tiles[i32(y1+dy*t)][i32(x1+dx*t)] != 0 { return false }
	}
	return true
}

reset_game :: proc(full: bool) {
	if full { game.level,game.health,game.kills = 1,player_settings.health,0 } else { game.level += 1 }
	generate()
	game.x,game.y,game.angle = 2,2,0
	game.enemy_count = min(MAX_ENEMIES, generator.starting_enemies+(game.level-1)*generator.enemies_per_level)
	for i in 0..<game.enemy_count {
		for {
			x,y := rl.GetRandomValue(3,MAP-2),rl.GetRandomValue(3,MAP-2)
			dx,dy := f32(x)-game.x,f32(y)-game.y
			if game.tiles[y][x] == 0 && dx*dx+dy*dy > 36 {
				game.enemies[i] = {x=f32(x)+.5,y=f32(y)+.5,hp=1+game.level/2,
					alive=true,kind=rl.GetRandomValue(0,2)}
				break
			}
		}
	}
}

strike :: proc(engine: ^rune.Engine, world: ^ecs.World) {
	if game.attack > 0 { return }
	game.attack = .34
	play_audio(engine, world, swing_audio)
	best: i32 = -1
	best_d := player_settings.attack_range
	for i in 0..<game.enemy_count {
		e := &game.enemies[i]
		if !e.alive { continue }
		dx,dy := e.x-game.x,e.y-game.y
		d := f32(math.sqrt(f64(dx*dx+dy*dy)))
		a := f32(math.atan2(f64(dy),f64(dx)))-game.angle
		for a > f32(math.PI) { a -= f32(math.PI*2) }
		for a < -f32(math.PI) { a += f32(math.PI*2) }
		if d < best_d && abs(a) < .24 && visible(game.x,game.y,e.x,e.y) { best,best_d=i,d }
	}
	if best >= 0 {
		e := &game.enemies[best]
		e.hp -= player_settings.attack_damage; play_audio(engine, world, hit_audio)
		if e.hp <= 0 { e.alive=false; game.kills+=1; play_audio(engine, world, death_audio) }
	}
}

dungeon_update_system :: proc(engine: ^rune.Engine, world: ^ecs.World) {
	dt := engine.delta_time
	player_transform, found := ecs.get_transform(world, player_entity)
	if !found { return }
	game.x = player_transform.position[0]
	game.y = player_transform.position[2]
	game.attack=max(0,game.attack-dt); game.hurt=max(0,game.hurt-dt)
	if game.health <= 0 {
		if rl.IsKeyPressed(.R) {
			reset_game(true)
			player_transform.position = {game.x, .58, game.y}
			ecs.set_transform(world, player_entity, player_transform)
		}
		return
	}
	game.angle += rl.GetMouseDelta().x*.0024
	if rl.IsKeyDown(.LEFT) { game.angle-=1.8*dt }
	if rl.IsKeyDown(.RIGHT) { game.angle+=1.8*dt }
	f,s := f32(0),f32(0)
	if rl.IsKeyDown(.W) { f+=1 }; if rl.IsKeyDown(.S) { f-=1 }
	if rl.IsKeyDown(.D) { s+=1 }; if rl.IsKeyDown(.A) { s-=1 }
	if f != 0 || s != 0 {
		l := f32(math.sqrt(f64(f*f+s*s))); f/=l; s/=l
		speed:=player_settings.walk_speed; if rl.IsKeyDown(.LEFT_SHIFT) { speed=player_settings.sprint_speed }
		c,sn := f32(math.cos(f64(game.angle))),f32(math.sin(f64(game.angle)))
		dx,dy := (c*f-sn*s)*speed*dt,(sn*f+c*s)*speed*dt
		if open(game.x+dx,game.y) { game.x+=dx }; if open(game.x,game.y+dy) { game.y+=dy }
		game.step-=dt; if game.step<=0 { play_audio(engine, world, footstep_audio); game.step=.42 }
	}
	if rl.IsMouseButtonPressed(.LEFT) || rl.IsKeyPressed(.SPACE) { strike(engine, world) }
	alive := 0
	for i in 0..<game.enemy_count {
		e := &game.enemies[i]; if !e.alive { continue }; alive+=1
		e.cooldown=max(0,e.cooldown-dt)
		dx,dy:=game.x-e.x,game.y-e.y; d:=f32(math.sqrt(f64(dx*dx+dy*dy)))
		if d<.7 && e.cooldown<=0 { game.health-=5+game.level;game.hurt=.25;e.cooldown=.9;play_audio(engine, world, hit_audio)
		} else if d<8 && visible(e.x,e.y,game.x,game.y) {
			v:=(.6+f32(game.level)*.04)*dt
			nx,ny:=e.x+dx/d*v,e.y+dy/d*v
			if open(nx,e.y){e.x=nx};if open(e.x,ny){e.y=ny}
		}
	}
	if alive==0 { play_audio(engine, world, level_audio);game.health=min(player_settings.health,game.health+25);reset_game(false) }
	player_transform.position = {game.x, .58, game.y}
	ecs.set_transform(world, player_entity, player_transform)
	camera, has_camera := ecs.get_camera_3d(world, player_entity)
	if has_camera {
		camera.target = {
			game.x + f32(math.cos(f64(game.angle))),
			.58,
			game.y + f32(math.sin(f64(game.angle))),
		}
		ecs.set_camera_3d(world, player_entity, camera)
	}
}

draw_wall_plane :: proc(texture: rl.Texture2D, a, b, c, d: rl.Vector3, tint: rl.Color) {
	rlgl.SetTexture(u32(texture.id))
	rlgl.Begin(rlgl.QUADS)
	rlgl.Color4ub(tint.r, tint.g, tint.b, tint.a)
	rlgl.TexCoord2f(0, 1); rlgl.Vertex3f(a.x, a.y, a.z)
	rlgl.TexCoord2f(1, 1); rlgl.Vertex3f(b.x, b.y, b.z)
	rlgl.TexCoord2f(1, 0); rlgl.Vertex3f(c.x, c.y, c.z)
	rlgl.TexCoord2f(0, 0); rlgl.Vertex3f(d.x, d.y, d.z)
	rlgl.End()
	rlgl.SetTexture(0)
}

draw_world :: proc(world: ^ecs.World) {
	transform, has_transform := ecs.get_transform(world, player_entity)
	camera_component, has_camera := ecs.get_camera_3d(world, player_entity)
	if !has_transform || !has_camera { return }
	camera := rl.Camera3D{
		position = transform.position,
		target = camera_component.target,
		up = camera_component.up,
		fovy = camera_component.fovy,
		projection = .PERSPECTIVE,
	}

	rl.BeginMode3D(camera)
	rl.DrawPlane({f32(MAP) / 2, 0, f32(MAP) / 2}, {f32(MAP), f32(MAP)}, {62, 48, 40, 255})
	rlgl.DisableBackfaceCulling()
	for y in 0..<MAP {
		for x in 0..<MAP {
			if game.tiles[y][x] == 0 { continue }
			fx, fz := f32(x), f32(y)
			tex := game.walls[(x * 7 + y * 13) & 3]
			if y == 0 || game.tiles[y-1][x] == 0 {
				draw_wall_plane(tex, {fx,0,fz},{fx+1,0,fz},{fx+1,generator.wall_height,fz},{fx,generator.wall_height,fz}, {185,185,195,255})
			}
			if y == MAP-1 || game.tiles[y+1][x] == 0 {
				draw_wall_plane(tex, {fx+1,0,fz+1},{fx,0,fz+1},{fx,generator.wall_height,fz+1},{fx+1,generator.wall_height,fz+1}, {165,165,175,255})
			}
			if x == 0 || game.tiles[y][x-1] == 0 {
				draw_wall_plane(tex, {fx,0,fz+1},{fx,0,fz},{fx,generator.wall_height,fz},{fx,generator.wall_height,fz+1}, {150,150,160,255})
			}
			if x == MAP-1 || game.tiles[y][x+1] == 0 {
				draw_wall_plane(tex, {fx+1,0,fz},{fx+1,0,fz+1},{fx+1,generator.wall_height,fz+1},{fx+1,generator.wall_height,fz}, {175,175,185,255})
			}
		}
	}
	rlgl.EnableBackfaceCulling()
	for i in 0..<game.enemy_count {
		e := game.enemies[i]
		if !e.alive { continue }
		tex := game.monsters[e.kind]
		rl.DrawBillboardRec(camera, tex, {0,0,f32(tex.width),f32(tex.height)},
			{e.x,.5,e.y}, {.9,.9}, rl.WHITE)
	}
	rl.EndMode3D()
}

dungeon_draw_system :: proc(engine: ^rune.Engine, world: ^ecs.World) {
	draw_world(world);w,h:=rl.GetScreenWidth(),rl.GetScreenHeight()
	scale:f32=7;ww:=f32(game.weapon.width)*scale;wh:=f32(game.weapon.height)*scale
	bob:=f32(math.sin(rl.GetTime()*8))*3;if game.attack>0{bob-=f32(math.sin(f64(game.attack/.34*f32(math.PI))))*38}
	rl.DrawTexturePro(game.weapon,{0,0,f32(game.weapon.width),f32(game.weapon.height)},
		{f32(w)/2-ww/2,f32(h)-wh+bob,ww,wh},{},0,rl.WHITE)
	rl.DrawRectangle(18,h-66,250,46,{5,4,5,220});rl.DrawRectangle(30,h-45,220,16,{60,15,18,255})
	rl.DrawRectangle(30,h-45,220*max(0,game.health)/100,16,{195,35,42,255})
	rl.DrawText(fmt.ctprintf("HEALTH %d",game.health),30,h-62,16,rl.RAYWHITE)
	rl.DrawText(fmt.ctprintf("DEPTH %d   KILLS %d",game.level,game.kills),18,18,22,{235,215,170,255})
	rl.DrawText("WASD move  Mouse look  LMB/Space attack  Shift sprint",18,48,16,{190,185,175,255})
	rl.DrawCircle(w/2,h/2,2,rl.GOLD)
	sc:i32=4;ox:i32=w-MAP*sc-18;oy:i32=18;rl.DrawRectangle(ox-4,oy-4,MAP*sc+8,MAP*sc+8,{0,0,0,160})
	for y in 0..<MAP{for x in 0..<MAP{if game.tiles[y][x]!=0{rl.DrawRectangle(ox+i32(x)*sc,oy+i32(y)*sc,sc,sc,{90,75,70,220})}}}
	rl.DrawCircle(ox+i32(game.x*f32(sc)),oy+i32(game.y*f32(sc)),3,rl.GOLD)
	if game.hurt>0{rl.DrawRectangle(0,0,w,h,{190,0,0,u8(game.hurt/.25*100)})}
	if game.health<=0{rl.DrawRectangle(0,0,w,h,{20,0,0,210});rl.DrawText("YOU DIED",w/2-rl.MeasureText("YOU DIED",64)/2,h/2-60,64,rl.RED)
		rl.DrawText("Press R to descend again",w/2-rl.MeasureText("Press R to descend again",24)/2,h/2+20,24,rl.RAYWHITE)}
}
