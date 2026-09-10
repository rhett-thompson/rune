package main

import "core:testing"
import "core:sync"
import "rune:assets"
import "rune:ecs"
import "rune:scene"

// The demo and ECS world generation use process-wide state.
demo_test_mutex:sync.Mutex
lock_demo_test :: proc() {sync.mutex_lock(&demo_test_mutex)}
unlock_demo_test :: proc() {sync.mutex_unlock(&demo_test_mutex)}

@(test)
ramp_reload_controls :: proc(t:^testing.T) {
	lock_demo_test();defer unlock_demo_test()
	r:=ecs.init_registry();defer ecs.destroy_registry(&r)
	testing.expect(t,ecs.register_builtin_components(&r))
	w,loaded:=scene.load("examples/navigation_3d/scenes/main.scene.json",&r)
	if !testing.expect(t,loaded) {return};defer ecs.destroy(&w)
	m:=assets.Asset_Manager{root="examples/navigation_3d",retained_paths=make(map[string]string),diagnostics=assets.init_diagnostic_log()}
	defer assets.shutdown(&m)
	ecs.sync_navigation_3d(&w,&m)
	e,_:=ecs.find_entity_by_id(&w,"navigation")
	mesh,_:=ecs.navigation_mesh_3d(&w,e)
	testing.expect(t,!ramp_is_closed(mesh))
	toggle_ramp(&w)
	// A value-only scene reload invokes enter without replacing mesh storage.
	enter(nil,&w)
	mesh,_=ecs.navigation_mesh_3d(&w,e)
	testing.expect(t,ramp_is_closed(mesh))
	toggle_ramp(&w)
	testing.expect(t,!ramp_is_closed(mesh),"one press reopens after a scene callback")
	toggle_ramp(&w)
	// Asset rebaking rebuilds the world mesh with clear blocked flags.
	ecs.remove_navigation_mesh_3d(&w,e);ecs.sync_navigation_3d(&w,&m)
	mesh,_=ecs.navigation_mesh_3d(&w,e)
	testing.expect(t,!ramp_is_closed(mesh))
	toggle_ramp(&w)
	testing.expect(t,ramp_is_closed(mesh),"one press closes after mesh replacement")
	a,_:=ecs.find_entity_by_id(&w,"agent")
	ecs.set_navigation_target_3d(&w,a,{7,2,3})
	ecs.update_navigation_3d(&w,1.0/60)
	state,_:=ecs.get_navigation_state_3d(&w,a)
	testing.expect(t,state.status==.No_Path,"closed ramp blocks the route")
	toggle_ramp(&w)
	for target in ([][3]f32{{7,2,3},{0,1,0},{-7,0,3},{7,2,-3},{-7,0,3}}) {
		ecs.set_navigation_target_3d(&w,a,target)
		for _ in 0..<1200 {ecs.update_navigation_3d(&w,1.0/60);ecs.physics_3d_update(&w,1.0/60)}
		state,_=ecs.get_navigation_state_3d(&w,a)
		testing.expect(t,state.status==.Arrived,"reopened ramp supports uphill, downhill and mid-ramp destinations")
	}
}
