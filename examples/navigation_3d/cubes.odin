package main

import "core:encoding/json"
import "core:fmt"
import rune "rune:core"
import "rune:console"
import "rune:ecs"
import "rune:navigation"
import rl "vendor:raylib"

Cube_Size :: f32(1.5)
Cube_Tag :: "navigation-placed-cube"
placing_cubes, cube_preview, cube_valid:bool
cube_center:[3]f32

placed_cube_count :: proc(world:^ecs.World) -> int {
	count:=0;for _,tag in world.entity_tags {if tag==Cube_Tag {count+=1}};return count
}
cube_position_clear :: proc(world:^ecs.World,center:[3]f32) -> bool {
	if !navigation.finite_point_3d(center) {return false}
	for v in center {if abs(v)>1000 {return false}}
	// A slight inset allows contact with supporting geometry without allowing
	// overlapping cubes. Queries also synchronize new colliders while paused.
	h:=Cube_Size*0.5-0.01
	if len(ecs.physics_3d_overlap_box(world,center,{h,h,h},{layers=~u64(0)}))>0 {return false}
	agent,found:=ecs.find_entity_by_id(world,"agent")
	if found {
		pose,ok:=ecs.get_transform(world,agent)
		motor,has_motor:=ecs.get_character_controller_3d(world,agent)
		if ok && has_motor && abs(pose.position.x-center.x)<h+motor.radius && abs(pose.position.z-center.z)<h+motor.radius &&
			pose.position.y<center.y+h && pose.position.y+motor.height>center.y-h {return false}
	}
	return true
}
cube_on_surface :: proc(point,normal:[3]f32) -> ([3]f32,bool) {
	if !navigation.finite_point_3d(point) || !navigation.finite_point_3d(normal) || normal.y<0.65 {return {},false}
	// Keep upright cubes above the uphill corner of ramps instead of embedding
	// their collision volume in the supporting surface.
	h:=Cube_Size*0.5
	return point+[3]f32{0,h+h*(abs(normal.x)+abs(normal.z))/normal.y,0},true
}
place_cube :: proc(game:^rune.Engine,world:^ecs.World,center:[3]f32) -> bool {
	if placed_cube_count(world)>=64 || !cube_position_clear(world,center) {
		console.warning(rune.developer_console(game),"Cube placement blocked: keep clear of objects and the agent (limit 64 cubes).")
		return false
	}
	e:=ecs.create_entity(world);if e==0 {return false}
	id:=fmt.tprintf("placed_cube_%d",ecs.entity_index(e))
	pose,pose_ok:=ecs.runtime_json(ecs.Transform{position=center,scale={1,1,1}})
	collider,collider_ok:=ecs.runtime_json(ecs.BoxCollider{size={Cube_Size,Cube_Size,Cube_Size},is_static=true,friction=0.8})
	ok:=pose_ok && collider_ok && ecs.set_entity_metadata(world,e,id,"Placed cube",Cube_Tag,ecs.Default_Layer_Mask) &&
		ecs.add_component(world,&game.registry,e,"Transform",pose) &&
		ecs.add_component(world,&game.registry,e,"BoxCollider",collider)
	if !ok {ecs.destroy_entity(world,e);return false}
	if !rebake_course(game,world) {ecs.destroy_entity(world,e);return false}
	console.info(rune.developer_console(game),"Cube placed; collision and navigation updated. Z undoes the last cube.")
	return true
}
undo_cube :: proc(game:^rune.Engine,world:^ecs.World) -> bool {
	last:ecs.Entity
	for e,tag in world.entity_tags {if tag==Cube_Tag && e>last {last=e}}
	if last==0 {return false}
	ecs.set_enabled(world,last,false)
	if !rebake_course(game,world) {ecs.set_enabled(world,last,true);return false}
	ecs.destroy_entity(world,last)
	console.info(rune.developer_console(game),"Last cube removed; navigation updated.")
	return true
}
cube_controls :: proc(game:^rune.Engine,world:^ecs.World) {
	cube_preview=false;cube_valid=false
	if !placing_cubes || rl.IsMouseButtonDown(.RIGHT) || rl.IsMouseButtonDown(.MIDDLE) {return}
	if rl.GetMousePosition().y<145 || rl.GetMousePosition().y>630 {return}
	agent,_:=ecs.find_entity_by_id(world,"agent")
	ray:=rl.GetScreenToWorldRay(rl.GetMousePosition(),camera)
	hit,found:=ecs.physics_3d_raycast(world,ray.position,ray.direction*150,{layers=~u64(0),ignore=agent})
	if !found {return}
	center,supported:=cube_on_surface(hit.point,hit.normal)
	if !supported {return}
	cube_center=center;cube_preview=true;cube_valid=cube_position_clear(world,center) && placed_cube_count(world)<64
	if rl.IsMouseButtonPressed(.LEFT) && cube_valid {
		place_cube(game,world,center)
		cube_preview=false
	}
}
draw_placed_cubes :: proc(world:^ecs.World) {
	for e,tag in world.entity_tags {
		if tag!=Cube_Tag || !ecs.is_enabled(world,e) {continue}
		pose,ok:=ecs.get_transform(world,e);if !ok {continue}
		rl.DrawCube(pose.position,Cube_Size,Cube_Size,Cube_Size,{180,120,65,255})
		rl.DrawCubeWires(pose.position,Cube_Size,Cube_Size,Cube_Size,{250,188,105,255})
	}
	if cube_preview {
		color:=rl.Color{105,230,155,255} if cube_valid else rl.Color{250,95,85,255}
		rl.DrawCubeWires(cube_center,Cube_Size,Cube_Size,Cube_Size,color)
	}
}
cube_command :: proc(c:^console.Console,args:string) {
	point:[3]f32
	if json.unmarshal(transmute([]u8)args,&point,allocator=context.temp_allocator)!=nil || !navigation.finite_point_3d(point) {
		console.error(c,"Usage: cube [x,y,z] (a point on a supporting surface)");return
	}
	game:=(^rune.Engine)(c.user_data);world:=&game.active_world
	agent,_:=ecs.find_entity_by_id(world,"agent")
	hit,found:=ecs.physics_3d_raycast(world,point+[3]f32{0,0.1,0},{0,-0.2,0},{layers=~u64(0),ignore=agent})
	if found {if center,ok:=cube_on_surface(hit.point,hit.normal);ok {place_cube(game,world,center);return}}
	console.error(c,"No supporting surface at that position.")
}
undo_cube_command :: proc(c:^console.Console,args:string) {
	game:=(^rune.Engine)(c.user_data)
	if !undo_cube(game,&game.active_world) {console.warning(c,"No cube removed.")}
}
