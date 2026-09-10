package main

import "core:fmt"
import example_text "../shared/text"
import rune "rune:core"
import "rune:ecs"
import "rune:console"
import "rune:navigation"
import rl "vendor:raylib"

camera := rl.Camera3D{position={17,20,23},target={1,0,0},up={0,1,0},fovy=45,projection=.PERSPECTIVE}
show_mesh:=true
destination: [3]f32
has_destination:bool

main :: proc() {
	orbit=default_course_camera()
	// On failure, engine loading may still use the last successfully baked asset.
	bake_course_startup()
	game,ok:=rune.init("examples/navigation_3d/project.json")
	if !ok {fmt.eprintln("Could not initialize navigation demo"); return}
	defer rune.shutdown(&game)
	if !example_text.init(&game.assets) {fmt.eprintln("Could not load shared example font");return}
	rune.register_system(&game,{name="navigation-demo",start=enter,on_scene_reloaded=reload_course,on_save_restored=reload_course,ui_update=controls,draw=draw})
	console.register(rune.developer_console(&game),"navigate","Route to the upper platform.",navigate_command)
	console.register(rune.developer_console(&game),"ramp","Close or reopen the ramp.",ramp_command)
	console.register(rune.developer_console(&game),"rebake","Bake navigation from the current scene geometry.",rebake_command)
	console.register(rune.developer_console(&game),"cube","Place a cube on a surface: cube [x,y,z].",cube_command)
	console.register(rune.developer_console(&game),"undo_cube","Remove the last placed cube and rebake.",undo_cube_command)
	rune.run_project(&game)
}
enter :: proc(game:^rune.Engine,world:^ecs.World) {has_destination=false;cube_preview=false}

// The mesh owns closure state. Scene value reloads retain its blocked flags;
// rebakes replace them. A separate toggle bool gets out of sync in both cases.
ramp_is_closed :: proc(mesh:navigation.Mesh_3D) -> bool {
	for triangle in mesh.triangles {if triangle.center.x>-2 && triangle.center.x<0 && triangle.blocked {return true}}
	return false
}
toggle_ramp :: proc(world:^ecs.World) {
	entity,found:=ecs.find_entity_by_id(world,"navigation");if !found {return}
	mesh,ready:=ecs.navigation_mesh_3d(world,entity);if !ready {return}
	closed:=!ramp_is_closed(mesh)
	for triangle,i in mesh.triangles {if triangle.center.x>-2 && triangle.center.x<0 {ecs.set_navigation_triangle_blocked_3d(world,entity,i32(i),closed)}}
}
ramp_command :: proc(c:^console.Console,args:string) {
	game:=(^rune.Engine)(c.user_data)
	toggle_ramp(&game.active_world)
	entity,found:=ecs.find_entity_by_id(&game.active_world,"navigation");if !found {return}
	mesh,_:=ecs.navigation_mesh_3d(&game.active_world,entity)
	console.info(c,"Ramp closed" if ramp_is_closed(mesh) else "Ramp open")
}
controls :: proc(game:^rune.Engine,world:^ecs.World) {
	cube_preview=false
	if console.is_open(rune.developer_console(game)) || !rl.IsWindowFocused() {return}
	update_course_camera(game,world)
	if rl.IsKeyPressed(.C) {placing_cubes=!placing_cubes}
	if rl.IsKeyPressed(.Z) {undo_cube(game,world)}
	if rl.IsKeyPressed(.N) {rebake_course(game,world)}
	mesh_entity,found:=ecs.find_entity_by_id(world,"navigation")
	if !found {return}
	mesh,ready:=ecs.navigation_mesh_3d(world,mesh_entity)
	if !ready {return}
	agent,_:=ecs.find_entity_by_id(world,"agent")
	if rl.IsKeyPressed(.P) {rune.set_paused(game,!rune.is_paused(game))}
	if rl.IsKeyPressed(.M) {show_mesh=!show_mesh}
	if rl.IsKeyPressed(.SPACE) {ecs.stop_navigation_3d(world,agent);has_destination=false}
	if rl.IsKeyPressed(.B) {
		toggle_ramp(world)
	}
	if placing_cubes {cube_controls(game,world);return}
	if rl.IsMouseButtonPressed(.LEFT) && !rl.IsMouseButtonDown(.RIGHT) && !rl.IsMouseButtonDown(.MIDDLE) {
		ray:=rl.GetScreenToWorldRay(rl.GetMousePosition(),camera)
		point,_,hit:=navigation.raycast_mesh_3d(&mesh,ray.position,ray.direction*100)
		if hit {destination=point;has_destination=true;ecs.set_navigation_target_3d(world,agent,point)}
	}
}
navigate_command :: proc(c:^console.Console,args:string) {
	game:=(^rune.Engine)(c.user_data)
	agent,found:=ecs.find_entity_by_id(&game.active_world,"agent")
	if found && ecs.set_navigation_target_3d(&game.active_world,agent,{7,2,3}) {destination={7,2,3};has_destination=true;console.info(c,"Upper platform destination set.")}
	else {console.error(c,"Navigation agent unavailable.")}
}
draw :: proc(game:^rune.Engine,world:^ecs.World) {
	mesh_entity,_:=ecs.find_entity_by_id(world,"navigation")
	mesh,ready:=ecs.navigation_mesh_3d(world,mesh_entity)
	agent,_:=ecs.find_entity_by_id(world,"agent")
	state,_:=ecs.get_navigation_state_3d(world,agent)
	pose,_:=ecs.get_transform(world,agent)
	rl.BeginMode3D(camera)
	if ready {
		for triangle in mesh.triangles {
			a,b,c:=mesh.vertices[triangle.vertices[0]],mesh.vertices[triangle.vertices[1]],mesh.vertices[triangle.vertices[2]]
			color:=rl.Color{57,97,108,255} if triangle.center.y<0.1 else rl.Color{67,117,105,255}
			if triangle.blocked {color={160,68,66,255}}
			rl.DrawTriangle3D(a,b,c,color);rl.DrawTriangle3D(c,b,a,color)
			if show_mesh {
				offset:=[3]f32{0,0.015,0}
				edge_color:=rl.Color{235,110,100,255} if triangle.blocked else rl.Color{90,150,160,255}
				rl.DrawLine3D(a+offset,b+offset,edge_color);rl.DrawLine3D(b+offset,c+offset,edge_color);rl.DrawLine3D(c+offset,a+offset,edge_color)
			}
		}
	}
	rl.DrawCube({-5,0.7,-1},1.3,1.4,1.3,{185,125,65,255})
	rl.DrawCubeWires({-5,0.7,-1},1.3,1.4,1.3,{240,175,105,255})
	draw_placed_cubes(world)
	rl.DrawCapsule(pose.position+[3]f32{0,0.35,0},pose.position+[3]f32{0,1.45,0},0.35,8,8,{105,195,255,255})
	for i in 1..<len(state.path) {rl.DrawLine3D(state.path[i-1]+[3]f32{0,0.08,0},state.path[i]+[3]f32{0,0.08,0},{255,225,115,255})}
	if has_destination {rl.DrawSphere(destination+[3]f32{0,0.13,0},0.13,{255,225,115,255})}
	rl.EndMode3D()
	example_text.draw("3D NAVIGATION",28,24,30,{225,235,245,255})
	example_text.draw("Click a surface to move   B close / open ramp   M mesh   Space stop   P pause",28,66,19,{175,195,210,255})
	example_text.draw("Right-drag orbit   Wheel zoom   Middle-drag pan   F focus agent   R reset view",28,94,17,{175,195,210,255})
	example_text.draw(fmt.ctprintf("C %s   Left-click %s   Z undo cube   |   %d cubes", "finish placing" if placing_cubes else "place cubes", "place at preview" if placing_cubes else "move agent",placed_cube_count(world)),28,122,17,{235,195,135,255})
	example_text.draw(fmt.ctprintf("Agent: %v    Path: %v    Ramp: %s%s",state.status,state.path_status,"Closed" if ramp_is_closed(mesh) else "Open","    PAUSED" if rune.is_paused(game) else ""),28,650,22,{225,235,245,255})
	if bake_failed {
		example_text.draw("Bake failed; previous mesh retained. See console for details. N retries.",28,688,17,{240,140,110,255})
	} else {
		example_text.draw(fmt.ctprintf("N rebake scene   |   %d navigation triangles   |   The separate island is unreachable.",baked_triangles),28,688,17,{155,175,190,255})
	}
}

