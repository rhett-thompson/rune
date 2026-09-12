package main

import "core:sync"
import "core:testing"
import "rune:ecs"

@(test)
health_damage_and_protection :: proc(t:^testing.T) {
	sync.mutex_lock(&interaction_test_lock);defer sync.mutex_unlock(&interaction_test_lock)
	reset_interactions();defer reset_interactions()
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);ecs.register_builtin_components(&r);register_course_components(&r)
	w:=ecs.init();defer ecs.destroy(&w)
	a:=test_entity(t,&w,&r,{3,0,3})
	test_add(t,&w,&r,a,"CharacterController3D",ecs.default_character_controller_3d())
	test_add(t,&w,&r,a,"RespawnPoint",Default_Respawn_Point)
	test_add(t,&w,&r,a,"Health",Default_Health)
	testing.expect(t,apply_damage(&w,a,0)==.Ignored && apply_damage(&w,a,-25)==.Ignored)
	testing.expect(t,apply_damage(&w,a,25)==.Hurt)
	value,_:=ecs.get(&w,a,Health)
	testing.expect(t,value.current==75 && value.protection_remaining==0.75)
	testing.expect(t,apply_damage(&w,a,25)==.Protected,"overlapping hazards cannot stack damage in one tick")
	update_course_health(&w,0);update_course_health(&w,-1)
	unchanged,_:=ecs.get(&w,a,Health)
	testing.expect(t,unchanged==value,"zero or invalid time does not advance timers")
	update_course_health(&w,0.75)
	testing.expect(t,apply_damage(&w,a,1000)==.Killed)
	value,_=ecs.get(&w,a,Health)
	testing.expect(t,value.current==0 && value.death_remaining==1.25,"lethal damage clamps at zero")
	testing.expect(t,apply_damage(&w,a,25)==.Ignored,"dead actors cannot be killed repeatedly")
	testing.expect(t,!update_course_health(&w,0.5) && actor_dead(&w,a))
	testing.expect(t,update_course_health(&w,0.75))
	value,_=ecs.get(&w,a,Health);pose,_:=ecs.get_transform(&w,a)
	testing.expect(t,value.current==100 && value.protection_remaining==1.5 && pose.position==Default_Respawn_Point.position)
	testing.expect(t,apply_damage(&w,a,25)==.Protected,"respawn grants protection")
	update_course_health(&w,1.5)
	ecs.set_enabled(&w,a,false)
	testing.expect(t,apply_damage(&w,a,25)==.Ignored,"disabled actors ignore damage")
	ecs.set_enabled(&w,a,true)
	testing.expect(t,apply_damage(&w,a,25)==.Hurt)
	invalid:=Default_Health;invalid.current=101
	testing.expect(t,!health_valid(invalid))
	data,_:=ecs.runtime_json(invalid)
	testing.expect(t,!restore_health(&w,a,data),"invalid saved health is rejected")
}
