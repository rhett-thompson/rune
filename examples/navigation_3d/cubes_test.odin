package main

import "core:os"
import "core:testing"
import "rune:assets"
import "rune:console"
import rune "rune:core"
import "rune:ecs"
import "rune:navigation"
import "rune:scene"

@(test)
cube_placement_collision_and_navigation :: proc(t:^testing.T) {
	lock_demo_test();defer unlock_demo_test()
	r:=ecs.init_registry();defer ecs.destroy_registry(&r)
	testing.expect(t,ecs.register_builtin_components(&r))
	w,loaded:=scene.load(Course_Root+"/scenes/main.scene.json",&r)
	if !testing.expect(t,loaded) {return};defer ecs.destroy(&w)
	path:="build/navigation-cube-test.navmesh.json";defer os.remove(path)
	nav,_:=ecs.find_entity_by_id(&w,"navigation")
	testing.expect(t,ecs.set(&w,nav,ecs.NavMesh3D{asset=path}))
	settings,error:=course_bake_settings();if !testing.expect(t,error=="") {return}
	_,error=bake_course_world(&w,".",settings);if !testing.expect(t,error=="",error) {return}
	game:=rune.Engine{registry=r,assets=assets.Asset_Manager{root=".",retained_paths=make(map[string]string),diagnostics=assets.init_diagnostic_log()},console=console.init()}
	defer assets.shutdown(&game.assets)
	ecs.sync_navigation_3d(&w,&game.assets)
	agent,_:=ecs.find_entity_by_id(&w,"agent")
	ecs.set_navigation_target_3d(&w,agent,{7,2,3})
	testing.expect(t,!cube_position_clear(&w,{-7,0.75,3}),"cannot place over the agent")
	testing.expect(t,!cube_position_clear(&w,{-5,0.75,-1}),"cannot overlap existing obstacle")
	center,ok:=cube_on_surface({4,2,0},{0,1,0});testing.expect(t,ok)
	placed:=place_cube(&game,&w,center)
	if !testing.expect(t,placed,"place cube on upper platform") {return}
	testing.expect(t,placed_cube_count(&w)==1)
	testing.expect(t,!cube_position_clear(&w,center),"cannot overlap placed cube")
	hit,found:=ecs.physics_3d_raycast(&w,{4,10,0},{0,-20,0})
	testing.expect(t,found && w.entity_tags[hit.entity]==Cube_Tag && abs(hit.point.y-3.5)<0.01,"cube has live static collision")
	mesh,_:=ecs.navigation_mesh_3d(&w,nav)
	_,_,on_floor:=navigation.project_point_3d(&mesh,{4,2,0},0.01)
	testing.expect(t,!on_floor,"cube removes ground beneath it from navigation")
	state,_:=ecs.get_navigation_state_3d(&w,agent)
	testing.expect(t,state.has_target && state.target==([3]f32{7,2,3}),"placement preserves active destination")
	// A failed rebake must undo the entity addition/removal as well.
	testing.expect(t,ecs.set(&w,nav,ecs.NavMesh3D{asset="invalid-output.txt"}))
	testing.expect(t,!place_cube(&game,&w,{6,2.75,0}) && placed_cube_count(&w)==1,"failed placement rolls back cube")
	testing.expect(t,!undo_cube(&game,&w) && ecs.is_enabled(&w,hit.entity),"failed undo restores cube")
	testing.expect(t,ecs.set(&w,nav,ecs.NavMesh3D{asset=path}))
	testing.expect(t,undo_cube(&game,&w) && placed_cube_count(&w)==0)
	mesh,_=ecs.navigation_mesh_3d(&w,nav)
	_,_,on_floor=navigation.project_point_3d(&mesh,{4,2,0},0.01)
	testing.expect(t,on_floor,"undo restores walkable ground")
	hit,found=ecs.physics_3d_raycast(&w,{4,10,0},{0,-20,0})
	testing.expect(t,found && abs(hit.point.y-2)<0.01,"undo removes cube collision")
}

