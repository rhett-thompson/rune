package main

import "core:fmt"
import "rune:ecs"
import bridge "rune:r3d_bridge"
import r3d "r3d:r3d"

expect_light_position :: proc(ctx:^bridge.Context,e:ecs.Entity,expected:[3]f32) {
	id,found:=ctx.scene_lights[e]
	assert(found && r3d.IsLightValid(id) && r3d.IsLightEnabled(id))
	position:=r3d.GetLightPosition(id)
	for axis in 0..<3 {assert(abs(position[axis]-expected[axis])<0.001,"native light/shadow origin must match rendered children")}
}

validate_light_hierarchy :: proc(ctx:^bridge.Context) {
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	w:=ecs.init(); defer ecs.destroy(&w)
	defer bridge.create_scene_lights(ctx,&w)
	root:=ecs.create_entity(&w)
	assert(ecs.add(&w,&r,root,ecs.Transform{position={10,20,30},rotation={0,90,0},scale={2,3,4}}))
	gap:=ecs.create_entity(&w); assert(ecs.set_parent(&w,gap,root))
	point:=ecs.create_entity(&w); assert(ecs.set_parent(&w,point,gap))
	spot:=ecs.create_entity(&w); assert(ecs.set_parent(&w,spot,gap))
	for entity in ([]ecs.Entity{point,spot}) {
		assert(ecs.add(&w,&r,entity,ecs.Transform{position={1,2,3},scale={1,1,1}}))
	}
	assert(ecs.add_component(&w,&r,point,"PointLight",parse(`{"intensity":1,"range":20,"shadows":true}`)))
	assert(ecs.add_component(&w,&r,spot,"SpotLight",parse(`{"intensity":1,"range":20,"shadows":true,"direction":[0,-1,0]}`)))
	for optimized in ([2]bool{true,false}) {
		ctx.render_optimizations_disabled=!optimized
		w.transforms[root]=ecs.Transform{position={10,20,30},rotation={0,90,0},scale={2,3,4}}
		bridge.create_scene_lights(ctx,&w)
		for entity in ([]ecs.Entity{point,spot}) {
			expect_light_position(ctx,entity,{22,26,28})
			assert(r3d.IsShadowEnabled(ctx.scene_lights[entity]))
		}
		// Spot direction is authored in world space, independent of entity rotation.
		assert(r3d.GetLightDirection(ctx.scene_lights[spot])==[3]f32{0,-1,0})
		// Direct parent edits must update even when no component revision changes.
		w.transforms[root]=ecs.Transform{position={-10,0,5},rotation={0,180,0},scale={3,2,1}}
		bridge.create_scene_lights(ctx,&w)
		for entity in ([]ecs.Entity{point,spot}) {expect_light_position(ctx,entity,{-13,4,2})}
		ecs.set_enabled(&w,root,false); bridge.create_scene_lights(ctx,&w)
		for entity in ([]ecs.Entity{point,spot}) {assert(!r3d.IsLightEnabled(ctx.scene_lights[entity]))}
		ecs.set_enabled(&w,root,true); bridge.create_scene_lights(ctx,&w)
		for entity in ([]ecs.Entity{point,spot}) {expect_light_position(ctx,entity,{-13,4,2})}
	}
	ctx.render_optimizations_disabled=false
	assert(ecs.set_parent(&w,point,0) && ecs.set_parent(&w,spot,0))
	bridge.create_scene_lights(ctx,&w)
	for entity in ([]ecs.Entity{point,spot}) {expect_light_position(ctx,entity,{1,2,3})}
	ecs.destroy_entity(&w,point); ecs.destroy_entity(&w,spot)
	bridge.create_scene_lights(ctx,&w)
	assert(len(ctx.scene_lights)==0,"removing children must release native lights and shadow state")
	fmt.println("Parented point/spot light and shadow origin validation passed")
}
