package main

import "core:fmt"
import "core:math"
import rune "rune:core"
import "rune:ecs"
import example_text "../shared/text"
import rl "vendor:raylib"
import b3 "vendor:box3d"

GOLD :: rl.Color{255,218,137,255}
INK :: rl.Color{9,16,33,235}
mix_color :: proc(a,b:rl.Color,amount:f32,light:f32=1)->rl.Color {
	t:=clamp(amount,0,1)
	return {u8(clamp((f32(a.r)+(f32(b.r)-f32(a.r))*t)*light,0,255)),
		u8(clamp((f32(a.g)+(f32(b.g)-f32(a.g))*t)*light,0,255)),
		u8(clamp((f32(a.b)+(f32(b.b)-f32(a.b))*t)*light,0,255)),255}
}
ring :: proc(center,up:V3,radius:f32,color:rl.Color) {
	x:=unit(cross(up,V3{0,0,1}));if math.abs(up[2])>0.95 {x=unit(cross(up,V3{1,0,0}))}
	y:=cross(up,x)
	for j in 0..<48 {
		a,b:=f32(j)*f32(math.TAU/48),f32(j+1)*f32(math.TAU/48)
		rl.DrawLine3D(rv(center+(x*math.cos(a)+y*math.sin(a))*radius),rv(center+(x*math.cos(b)+y*math.sin(b))*radius),color)
	}
}
draw :: proc(game:^rune.Engine,world:^ecs.World) {
	// Distant stars are fixed world directions, so camera orbit has real parallax.
	rl.BeginMode3D(camera)
	for j in 0..<500 {
		a:=f32(j)*2.399963
		y:=1-2*(f32(j)+0.5)/500
		r:=math.sqrt(1-y*y)
		p:=V3{r*math.cos(a),y,r*math.sin(a)}*210
		rl.DrawSphere(rv(p),0.1+f32(j%4)*0.04,rl.Color{145,166,204,255})
	}
	for planet,i in PLANETS {
		mesh:=&meshes[i]
		for j:=0;j<len(mesh.indices);j+=3 {
			a,b,c:=mesh.vertices[mesh.indices[j]],mesh.vertices[mesh.indices[j+1]],mesh.vertices[mesh.indices[j+2]]
			n:=unit(cross(b-a,c-a))
			height:=(length((a+b+c)/3)-planet.radius*0.79)/max(planet.relief*1.4,0.1)
			light:=0.58+0.42*max(0,dot(n,unit({-0.5,0.9,0.6})))
			color:=mix_color(planet.low,planet.high,height,light)
			rl.DrawTriangle3D(rv(a+planet.center),rv(b+planet.center),rv(c+planet.center),color)
		}
		up:=gate_direction(i);gate:=gates[i]
		// A launch marker points along the next gravity well, without teleporting.
		ring(gate+up*0.07,up,1.25,GOLD);ring(gate+up*0.1,up,1.05,GOLD)
		for k in 0..<3 {ring(gate+up*(0.9+f32(k)*0.55),up,0.45-f32(k)*0.09,rl.Fade(GOLD,0.9-f32(k)*0.2))}
		rl.DrawCylinderEx(rv(gate),rv(gate+up*1.9),0.025,0.025,6,GOLD)
		// Dotted flight line stops before the next surface.
		next:=(i+1)%len(PLANETS)
		end:=PLANETS[next].center-up*(PLANETS[next].radius+0.6)
		for k in 0..<16 {
			t:=f32(k)/16
			p:=gate+up*2+(end-gate-up*2)*t
			rl.DrawSphere(rv(p),0.055,rl.Fade(GOLD,0.8))
		}
	}
	for entity in rocks {
		if native,ok:=ecs.physics_3d_native_body(world,entity);ok {
			p:=b3.Body_GetPosition(native);position:=V3{f32(p.x),f32(p.y),f32(p.z)}
			rl.DrawSphereEx(rv(position),0.38,4,6,rl.Color{211,172,99,255})
			marker:=b3.RotateVector(b3.Body_GetRotation(native),{0,0.35,0})
			rl.DrawSphere(rv(position+V3{marker.x,marker.y,marker.z}),0.1,INK)
		}
	}
	draw_avatar(world,game)
	rl.EndMode3D()
}
draw_avatar :: proc(world:^ecs.World,game:^rune.Engine) {
	if actual_distance<1.6 {return}
	motor,_:=ecs.get_character_controller_3d_state(world,player)
	pose,_:=ecs.get_transform(world,player)
	position:=pose.position
	if motor.active {position=motor.previous_position+(position-motor.previous_position)*clamp(game.fixed_accumulator/game.fixed_delta_time,0,1)}
	up,forward:=avatar_up,avatar_forward
	right:=unit(cross(forward,up))
	height:=motor.height;if height<=0 {height=1.8}
	scale:=height/1.8
	bob:=f32(0);if motor.grounded {bob=math.sin(walk_phase)*0.065}
	white:=rl.Color{234,242,237,255};dark:=rl.Color{27,43,65,255}
	rl.DrawCapsule(rv(position+up*(0.62*scale)),rv(position+up*(1.13*scale)),0.3,8,4,white)
	rl.DrawSphere(rv(position+up*(1.47*scale)),0.34,white)
	rl.DrawSphere(rv(position+up*(1.47*scale)+forward*0.2),0.27,dark)
	rl.DrawSphere(rv(position+up*(1.51*scale)+forward*0.41+right*0.09),0.065,rl.Color{120,219,226,255})
	for sign in ([2]f32{-1,1}) {
		leg:=position+right*(sign*0.18)
		rl.DrawCapsule(rv(leg+up*0.16+forward*(bob*sign)),rv(leg+up*(0.55*scale)),0.13,6,3,dark)
		arm:=position+right*(sign*0.38)+up*(0.95*scale)
		rl.DrawCapsule(rv(arm-up*0.23+forward*(bob*sign)),rv(arm+up*0.18),0.105,6,3,white)
	}
	rl.DrawCapsule(rv(position+up*(0.7*scale)-forward*0.29),rv(position+up*(1.12*scale)-forward*0.29),0.18,6,3,GOLD)
}
draw_ui :: proc(game:^rune.Engine,world:^ecs.World) {
	w,h:=rl.GetScreenWidth(),rl.GetScreenHeight()
	rl.DrawRectangle(24,24,330,107,INK)
	example_text.draw("P O C K E T   P L A N E T S",42,38,22,rl.RAYWHITE)
	example_text.draw("A tiny gravity-hopping expedition",42,69,15,rl.Color{147,172,191,255})
	count:=0;for v in visited {if v {count+=1}}
	example_text.draw(fmt.ctprintf("%02d / 04  WORLDS EXPLORED",count),42,101,14,GOLD)
	rl.DrawRectangle(w-232,24,208,155,INK)
	for planet,i in PLANETS {
		y:=43+i32(i)*33
		rl.DrawCircle(w-211,y+6,4,planet.high)
		example_text.draw(planet.name,w-197,y-2,15,rl.RAYWHITE if source==i else rl.Color{143,160,186,255})
		if visited[i] {example_text.draw("OK",w-64,y-2,13,GOLD)}
	}
	motor,_:=ecs.get_character_controller_3d_state(world,player)
	pose,_:=ecs.get_transform(world,player)
	near_gate:=length(pose.position-gates[source])<2.4
	message:cstring="Find the golden beacon. Hold your jump to reach another world."
	if near_gate {message="LAUNCH POINT  /  Hold SPACE; release movement to drift toward the next world."}
	if !motor.grounded {message="IN FLIGHT  /  Steer with WASD. Gravity catches you near the next world."}
	if count==4 {message="EXPEDITION COMPLETE  /  All four worlds explored. Keep wandering!"}
	rl.DrawRectangle(24,h-108,w-48,84,INK)
	example_text.draw(message,42,h-94,17,GOLD)
	example_text.draw("WASD  move     SPACE  jump (hold for height)     SHIFT  sprint     CTRL  crouch",42,h-64,15,rl.RAYWHITE)
	example_text.draw("Mouse drag  orbit     Wheel  zoom     R  restart",42,h-42,14,rl.Color{147,172,191,255})
}
