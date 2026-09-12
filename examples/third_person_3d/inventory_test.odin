package main

import "core:os"
import "core:sync"
import "core:testing"
import "rune:ecs"
import "rune:input"
import "rune:save"
import "rune:scene"

@(test)
inventory_checkpoint_round_trip :: proc(t:^testing.T) {
	sync.mutex_lock(&interaction_test_lock);defer sync.mutex_unlock(&interaction_test_lock)
	reset_interactions();defer reset_interactions()
	controls,input_ok:=input.load("examples/third_person_3d/input/default.input.json")
	if !testing.expect(t,input_ok,"checkpoint key bindings load") {return};defer input.destroy(&controls)
	testing.expect(t,input.key_from_name("F5").key==.F5 && input.key_from_name("f9").key==.F9)
	testing.expect(t,input.key_from_name("F12").key==.F12 && !input.key_from_name("F13").valid)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r)
	testing.expect(t,ecs.register_builtin_components(&r) && register_course_components(&r))
	layers:=make(map[string]u8);defer delete(layers)
	layers["Gameplay"]=1;layers["Player"]=2
	w,loaded:=scene.load_with_layers("examples/third_person_3d/scenes/main.scene.json",&r,layers)
	defer scene.clear_load_error()
	if !testing.expect(t,loaded,scene.last_load_error()) {return};defer ecs.destroy(&w)
	options:=save.Options{game_id="third-person-inventory-test",game_version=1,directory="build/interaction-save-test"}
	m,ready:=save.init("examples/third_person_3d",options)
	defer save.destroy(&m)
	if !testing.expect(t,ready && register_course_saves(&m,&r),save.last_error(&m)) {return}
	defer {
		for slot in ([]string{"locked","progress","dead"}) {
			path,_:=save.slot_path(&m,slot);os.remove(path)
			backup,_:=save.slot_path(&m,slot,true);os.remove(backup)
		}
	}
	testing.expect(t,save.begin_scene(&m,&w,"scenes/main.scene.json"))
	testing.expect(t,save.capture(&m,&w) && save.write_slot(&m,"locked"),save.last_error(&m))
	a,_:=ecs.find_entity_by_id(&w,"player")
	pickup,_:=ecs.find_entity_by_id(&w,"interaction_pickup")
	door,_:=ecs.find_entity_by_id(&w,"interaction_door")
	testing.expect(t,!inventory_add(&w,a,"brass_key",0) && !inventory_add(&w,a,"",1),"invalid additions rejected")
	activate_course_interaction(&w,pickup)
	testing.expect(t,inventory_summary(&w,a)=="Inventory: Brass key x1")
	activate_course_interaction(&w,door)
	update_course_door(&w,0.3)
	saved_pose,_:=ecs.get_transform(&w,door)
	testing.expect(t,saved_pose.position.y>Door_Closed_Y && saved_pose.position.y<Door_Open_Y)
	ecs.character_controller_3d_teleport(&w,a,{-5,0,8})
	ecs.update_triggers_3d(&w);process_course_zones(&w)
	testing.expect(t,apply_damage(&w,a,25)==.Hurt)
	update_course_health(&w,0.15)
	testing.expect(t,save.capture(&m,&w) && save.write_slot(&m,"progress"),save.last_error(&m))
	// Load through an entirely new manager, as after restarting the program.
	fresh,initialized:=save.init("examples/third_person_3d",options)
	defer save.destroy(&fresh)
	if !testing.expect(t,initialized && register_course_saves(&fresh,&r)) {return}
	checkpoint,read:=save.read_slot(&fresh,"progress")
	if !testing.expect(t,read,save.last_error(&fresh)) {return};defer save.destroy_checkpoint(&checkpoint)
	restored,prepared:=save.prepare_scene(&fresh,&checkpoint,"scenes/main.scene.json",&r,layers)
	if !testing.expect(t,prepared,save.last_error(&fresh)) {return};defer ecs.destroy(&restored)
	ra,_:=ecs.find_entity_by_id(&restored,"player")
	rp,_:=ecs.find_entity_by_id(&restored,"interaction_pickup")
	rd,_:=ecs.find_entity_by_id(&restored,"interaction_door")
	testing.expect(t,ra!=a && inventory_count(&restored,ra,"brass_key")==1,"inventory survives world replacement")
	saved_health,_:=ecs.get(&w,a,Health)
	restored_health,_:=ecs.get(&restored,ra,Health)
	testing.expect(t,restored_health==saved_health && restored_health.current==75,"health and remaining hit protection survive save/load")
	testing.expect(t,apply_damage(&restored,ra,25)==.Protected,"loading preserves hit protection")
	restored_spawn,_:=ecs.get(&restored,ra,Respawn_Point)
	testing.expect(t,restored_spawn.checkpoint.id=="checkpoint_zone" && restored_spawn.position==([3]f32{-5,0.05,8}),"activated respawn point persists")
	testing.expect(t,len(ecs.trigger_events_3d(&restored))==0,"trigger membership is transient across restore")
	testing.expect(t,!ecs.is_enabled(&restored,rp),"collected pickup stays gone")
	head,_:=ecs.find_entity_by_id(&restored,"key_head")
	testing.expect(t,!ecs.is_enabled(&restored,head),"pickup children stay hidden")
	state,_:=ecs.get(&restored,rd,Door_State)
	pose,_:=ecs.get_transform(&restored,rd)
	testing.expect(t,state.unlocked && state.open && pose.position==saved_pose.position,"door unlock, destination, and partial position restored")
	reset_interactions();refresh_course_door_prompt(&restored)
	for _ in 0..<60 {update_course_door(&restored,1.0/60)}
	pose,_=ecs.get_transform(&restored,rd)
	testing.expect(t,pose.position.y==Door_Open_Y,"restored animation continues to its endpoint")
	testing.expect(t,inventory_count(&restored,ra,"brass_key")==1,"unlocking retains the reusable key")
	testing.expect(t,!inventory_add(&restored,ra,"brass_key",99) && inventory_count(&restored,ra,"brass_key")==1,"stack overflow is atomic")
	activate_course_interaction(&restored,rp)
	testing.expect(t,inventory_count(&restored,ra,"brass_key")==1,"loading cannot duplicate a collected key")
	before,read_before:=save.read_slot(&fresh,"locked")
	if !testing.expect(t,read_before) {return};defer save.destroy_checkpoint(&before)
	initial,initial_ok:=save.prepare_scene(&fresh,&before,"scenes/main.scene.json",&r,layers)
	if !testing.expect(t,initial_ok) {return};defer ecs.destroy(&initial)
	initial_player,_:=ecs.find_entity_by_id(&initial,"player")
	initial_pickup,_:=ecs.find_entity_by_id(&initial,"interaction_pickup")
	initial_door,_:=ecs.find_entity_by_id(&initial,"interaction_door")
	initial_state,_:=ecs.get(&initial,initial_door,Door_State)
	initial_health,_:=ecs.get(&initial,initial_player,Health)
	testing.expect(t,initial_health.current==100,"earlier checkpoint restores earlier health")
	testing.expect(t,inventory_count(&initial,initial_player,"brass_key")==0 && ecs.is_enabled(&initial,initial_pickup) && !initial_state.unlocked,
		"earlier checkpoint restores empty inventory, available key, and locked door together")
	update_course_health(&w,1)
	testing.expect(t,apply_damage(&w,a,1000)==.Killed)
	update_course_health(&w,0.25)
	testing.expect(t,save.capture(&m,&w) && save.write_slot(&m,"dead"),save.last_error(&m))
	dead_save,dead_read:=save.read_slot(&fresh,"dead")
	if !testing.expect(t,dead_read) {return};defer save.destroy_checkpoint(&dead_save)
	dead_world,dead_loaded:=save.prepare_scene(&fresh,&dead_save,"scenes/main.scene.json",&r,layers)
	if !testing.expect(t,dead_loaded,save.last_error(&fresh)) {return};defer ecs.destroy(&dead_world)
	dead_actor,_:=ecs.find_entity_by_id(&dead_world,"player")
	dead_health,_:=ecs.get(&dead_world,dead_actor,Health)
	testing.expect(t,dead_health.current==0 && dead_health.death_remaining==1,"mid-death checkpoint retains countdown")
	testing.expect(t,!update_course_health(&dead_world,0.5) && update_course_health(&dead_world,0.5),"restored death countdown finishes normally")
}
