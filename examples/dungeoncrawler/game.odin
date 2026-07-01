package main

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strings"
import rune "rune:core"
import "rune:assets"
import rl "vendor:raylib"

MAP :: 31
MAX_ENEMIES :: 32
FOV :: f32(math.PI / 3)

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
	hit, swing, death, footstep, clear: rl.Sound,
	music: rl.Music,
}

game: Dungeon

get_texture :: proc(engine: ^rune.Engine, path: string) -> rl.Texture2D {
	value, _ := assets.texture(&engine.assets, path)
	rl.SetTextureFilter(value, .POINT)
	return value
}

get_sound :: proc(path: string) -> rl.Sound {
	c, _ := strings.clone_to_cstring(path)
	return rl.LoadSound(c)
}

load_assets :: proc(engine: ^rune.Engine, project_directory: string) {
	game.walls = {
		get_texture(engine, "assets/textures/wall.png"),
		get_texture(engine, "assets/textures/wallCracked.png"),
		get_texture(engine, "assets/textures/wallDark.png"),
		get_texture(engine, "assets/textures/wallVines.png"),
	}
	game.monsters = {
		get_texture(engine, "assets/textures/skeletonWarrior.png"),
		get_texture(engine, "assets/textures/ogre.png"),
		get_texture(engine, "assets/textures/flameSkull.png"),
	}
	game.weapon = get_texture(engine, "assets/textures/swordUI.png")
	hit_path, _ := filepath.join({project_directory, "assets", "sounds", "hit_2.mp3"})
	swing_path, _ := filepath.join({project_directory, "assets", "sounds", "blade_2.mp3"})
	death_path, _ := filepath.join({project_directory, "assets", "sounds", "death_3.mp3"})
	step_path, _ := filepath.join({project_directory, "assets", "sounds", "footstep.mp3"})
	clear_path, _ := filepath.join({project_directory, "assets", "sounds", "potion.mp3"})
	music_path, _ := filepath.join({project_directory, "assets", "music", "music_1.mp3"})
	game.hit = get_sound(hit_path)
	game.swing = get_sound(swing_path)
	game.death = get_sound(death_path)
	game.footstep = get_sound(step_path)
	game.clear = get_sound(clear_path)
	c, _ := strings.clone_to_cstring(music_path)
	game.music = rl.LoadMusicStream(c)
	rl.SetMusicVolume(game.music, .4)
	rl.PlayMusicStream(game.music)
}

unload_audio :: proc() {
	rl.UnloadSound(game.hit)
	rl.UnloadSound(game.swing)
	rl.UnloadSound(game.death)
	rl.UnloadSound(game.footstep)
	rl.UnloadSound(game.clear)
	rl.UnloadMusicStream(game.music)
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
	for _ in 0..<5 {
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
	if full { game.level,game.health,game.kills = 1,100,0 } else { game.level += 1 }
	generate()
	game.x,game.y,game.angle = 2,2,0
	game.enemy_count = min(MAX_ENEMIES, 10+game.level*3)
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

strike :: proc() {
	if game.attack > 0 { return }
	game.attack = .34
	rl.PlaySound(game.swing)
	best: i32 = -1
	best_d := f32(2.2)
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
		e.hp -= 1; rl.PlaySound(game.hit)
		if e.hp <= 0 { e.alive=false; game.kills+=1; rl.PlaySound(game.death) }
	}
}

update_game :: proc(engine: ^rune.Engine) {
	dt := engine.delta_time
	rl.UpdateMusicStream(game.music)
	game.attack=max(0,game.attack-dt); game.hurt=max(0,game.hurt-dt)
	if game.health <= 0 { if rl.IsKeyPressed(.R) { reset_game(true) }; return }
	game.angle += rl.GetMouseDelta().x*.0024
	if rl.IsKeyDown(.LEFT) { game.angle-=1.8*dt }
	if rl.IsKeyDown(.RIGHT) { game.angle+=1.8*dt }
	f,s := f32(0),f32(0)
	if rl.IsKeyDown(.W) { f+=1 }; if rl.IsKeyDown(.S) { f-=1 }
	if rl.IsKeyDown(.D) { s+=1 }; if rl.IsKeyDown(.A) { s-=1 }
	if f != 0 || s != 0 {
		l := f32(math.sqrt(f64(f*f+s*s))); f/=l; s/=l
		speed:f32=3; if rl.IsKeyDown(.LEFT_SHIFT) { speed=4.5 }
		c,sn := f32(math.cos(f64(game.angle))),f32(math.sin(f64(game.angle)))
		dx,dy := (c*f-sn*s)*speed*dt,(sn*f+c*s)*speed*dt
		if open(game.x+dx,game.y) { game.x+=dx }; if open(game.x,game.y+dy) { game.y+=dy }
		game.step-=dt; if game.step<=0 { rl.PlaySound(game.footstep); game.step=.42 }
	}
	if rl.IsMouseButtonPressed(.LEFT) || rl.IsKeyPressed(.SPACE) { strike() }
	alive := 0
	for i in 0..<game.enemy_count {
		e := &game.enemies[i]; if !e.alive { continue }; alive+=1
		e.cooldown=max(0,e.cooldown-dt)
		dx,dy:=game.x-e.x,game.y-e.y; d:=f32(math.sqrt(f64(dx*dx+dy*dy)))
		if d<.7 && e.cooldown<=0 { game.health-=5+game.level;game.hurt=.25;e.cooldown=.9;rl.PlaySound(game.hit)
		} else if d<8 && visible(e.x,e.y,game.x,game.y) {
			v:=(.6+f32(game.level)*.04)*dt
			nx,ny:=e.x+dx/d*v,e.y+dy/d*v
			if open(nx,e.y){e.x=nx};if open(e.x,ny){e.y=ny}
		}
	}
	if alive==0 { rl.PlaySound(game.clear);game.health=min(100,game.health+25);reset_game(false) }
}

draw_world :: proc() {
	w,h:=rl.GetScreenWidth(),rl.GetScreenHeight(); mid:=h/2
	rl.DrawRectangle(0,0,w,mid,{12,9,17,255})
	rl.DrawRectangleGradientV(0,mid,w,h-mid,{48,37,31,255},{10,8,8,255})
	z:=make([]f32,w);defer delete(z)
	for col in 0..<w {
		a:=game.angle-FOV/2+FOV*f32(col)/f32(w);rx:=f32(math.cos(f64(a)));ry:=f32(math.sin(f64(a)))
		mx,my:=i32(game.x),i32(game.y);ddx,ddy:=abs(1/rx),abs(1/ry)
		sx,sy:i32;dx,dy:f32
		if rx<0{sx=-1;dx=(game.x-f32(mx))*ddx}else{sx=1;dx=(f32(mx+1)-game.x)*ddx}
		if ry<0{sy=-1;dy=(game.y-f32(my))*ddy}else{sy=1;dy=(f32(my+1)-game.y)*ddy}
		side:=0
		for {if dx<dy{dx+=ddx;mx+=sx;side=0}else{dy+=ddy;my+=sy;side=1};if game.tiles[my][mx]!=0{break}}
		d:=dx-ddx;if side==1{d=dy-ddy};d*=f32(math.cos(f64(a-game.angle)));d=max(.02,d);z[col]=d
		lh:=min(h*2,i32(f32(h)/d));top:=mid-lh/2
		wx:=game.y+d*ry;if side==1{wx=game.x+d*rx};wx-=f32(math.floor(f64(wx)))
		t:=game.walls[(mx*7+my*13)&3];tint:=rl.WHITE;if side==1{tint={170,170,180,255}}
		rl.DrawTexturePro(t,{f32(i32(wx*f32(t.width))%t.width),0,1,f32(t.height)},
			{f32(col),f32(top),1,f32(lh)},{},0,tint)
	}
	for i in 0..<game.enemy_count {
		e:=game.enemies[i];if !e.alive{continue}
		dx,dy:=e.x-game.x,e.y-game.y;d:=f32(math.sqrt(f64(dx*dx+dy*dy)))
		a:=f32(math.atan2(f64(dy),f64(dx)))-game.angle
		for a>f32(math.PI){a-=f32(math.PI*2)};for a< -f32(math.PI){a+=f32(math.PI*2)}
		if abs(a)>FOV*.7||d<.2{continue}
		size:=min(h*2,i32(f32(h)/d));left:=i32((.5+a/FOV)*f32(w))-size/2;top:=mid-size/2;t:=game.monsters[e.kind]
		for stripe in 0..<size {x:=left+stripe;if x<0||x>=w||d>=z[x]{continue}
			rl.DrawTexturePro(t,{f32(stripe)*f32(t.width)/f32(size),0,1,f32(t.height)},
				{f32(x),f32(top),1,f32(size)},{},0,rl.WHITE)}
	}
}

draw_game :: proc(engine: ^rune.Engine) {
	draw_world();w,h:=rl.GetScreenWidth(),rl.GetScreenHeight()
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
