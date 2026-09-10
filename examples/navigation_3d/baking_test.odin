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
bake_without_existing_asset :: proc(t:^testing.T) {
	lock_demo_test();defer unlock_demo_test()
	r:=ecs.init_registry();defer ecs.destroy_registry(&r)
	testing.expect(t,ecs.register_builtin_components(&r))
	w,loaded:=scene.load(Course_Root+"/scenes/main.scene.json",&r)
	if !testing.expect(t,loaded) {return};defer ecs.destroy(&w)
	entity,_:=ecs.find_entity_by_id(&w,"navigation")
	path:="build/navigation-demo-bake-test.navmesh.json"
	os.remove(path);defer os.remove(path)
	testing.expect(t,ecs.set(&w,entity,ecs.NavMesh3D{asset=path}))
	settings,error:=course_bake_settings()
	if !testing.expect(t,error=="",error) {return}
	stats,bake_error:=bake_course_world(&w,".",settings)
	if !testing.expect(t,bake_error=="",bake_error) {return}
	testing.expect(t,stats.output_triangles>0 && os.exists(path),"bake creates the missing asset")
	game:=rune.Engine{assets=assets.Asset_Manager{root=".",retained_paths=make(map[string]string),diagnostics=assets.init_diagnostic_log()},console=console.init()}
	defer assets.shutdown(&game.assets)
	ecs.sync_navigation_3d(&w,&game.assets)
	toggle_ramp(&w)
	agent,_:=ecs.find_entity_by_id(&w,"agent")
	ecs.set_navigation_target_3d(&w,agent,{7,2,3})
	before:=w.navigation_3d.meshes[entity].revision
	rebake_course(&game,&w)
	mesh,_:=ecs.navigation_mesh_3d(&w,entity)
	testing.expect(t,!bake_failed && w.navigation_3d.meshes[entity].revision>before,"rebake installs immediately")
	testing.expect(t,ramp_is_closed(mesh),"rebake preserves the closed ramp")
	state,_:=ecs.get_navigation_state_3d(&w,agent)
	testing.expect(t,state.has_target && state.target==([3]f32{7,2,3}),"rebake retains the requested destination")
	toggle_ramp(&w)
	for _ in 0..<1200 {ecs.update_navigation_3d(&w,1.0/60);ecs.physics_3d_update(&w,1.0/60)}
	state,_=ecs.get_navigation_state_3d(&w,agent)
	testing.expect(t,state.status==.Arrived,"agent traverses newly baked ramp")
	// Make all source collision unavailable: the failed bake must not replace
	// either the existing file or the active mesh/revision.
	for e in w.box_colliders {ecs.set_enabled(&w,e,false)}
	bytes,_:=os.read_entire_file(path,context.allocator);defer delete(bytes)
	before=w.navigation_3d.meshes[entity].revision
	rebake_course(&game,&w)
	after,_:=os.read_entire_file(path,context.allocator);defer delete(after)
	testing.expect(t,bake_failed && string(bytes)==string(after),"failed bake retains the asset")
	testing.expect(t,w.navigation_3d.meshes[entity].revision==before,"failed bake retains the active mesh")
	_,_,valid:=navigation.project_point_3d(&mesh,{7,2,3},0.1)
	testing.expect(t,valid,"previous geometry remains usable")
}
