package ecs

import "core:encoding/json"
import "core:math"

// Interaction points are Transform positions plus an unscaled world-axis offset.
// Game code owns the result (doors, dialogue, inventory, etc.). No input or UI
// dependency is imposed on the engine, and each character owns its own state.
Interactable3D :: struct {
	prompt: string,
	offset: [3]f32,
	hold_seconds: f32,
	enabled: bool,
}
Interactor3D :: struct {
	range, half_angle: f32,
	target_layers, obstruction_layers: u64,
	require_line_of_sight: bool,
}
Default_Interactable_3D :: Interactable3D{prompt="Use", enabled=true}
Default_Interactor_3D :: Interactor3D{range=3, half_angle=65, target_layers=~u64(0), obstruction_layers=~u64(0), require_line_of_sight=true}

interaction_component_3d_valid :: proc(value:$T) -> bool {
	when T == Interactable3D {
		return value.prompt!="" && physics_query_vector_valid(value.offset) && finite_nonnegative(value.hold_seconds)
	} else when T == Interactor3D {
		return finite_nonnegative(value.range) && value.range>0 && finite_nonnegative(value.half_angle) && value.half_angle<=180
	}
}
interaction_component_3d_from_json :: proc(data:json.Value, $T:typeid) -> (T,bool) {
	result:T
	when T == Interactable3D {result=Default_Interactable_3D}
	when T == Interactor3D {result=Default_Interactor_3D}
	if !json_shape_matches_type(data,T) {return {},false}
	bytes,err:=json.marshal(data,allocator=context.temp_allocator)
	if err!=nil || json.unmarshal(bytes,&result,allocator=context.temp_allocator)!=nil {return {},false}
	return result,interaction_component_3d_valid(result)
}

Interaction_Focus_3D :: struct {entity:Entity, point:[3]f32, distance:f32}
Interaction_State_3D :: struct {
	actor: Entity,
	focus: Interaction_Focus_3D,
	progress: f32, // 0..1 for a hold; completion is returned exactly once.
	// Bookkeeping contains no borrowed data; reset the struct to cancel it.
	elapsed: f32,
	was_down, holding: bool,
	target_version, actor_version: u64,
}

// origin is the character's reach/eye position, not a distant orbit camera.
// forward may be character-facing or camera-facing, according to the game.
// Prefer the most centered visible target, then distance, then entity handle.
find_interaction_3d :: proc(world:^World, actor:Entity, origin,forward:[3]f32) -> Interaction_Focus_3D {
	config,found:=get(world,actor,Interactor3D)
	if !found || !is_enabled(world,actor) || !has_component_data(world,actor,"Transform") ||
	   !physics_query_vector_valid(origin) || !physics_query_vector_valid(forward) {return {}}
	length:=math.sqrt(forward.x*forward.x+forward.y*forward.y+forward.z*forward.z)
	if !finite_nonnegative(length) || length<0.00001 {return {}}
	direction:=forward/length
	min_dot:=math.cos(config.half_angle*f32(math.PI/180))
	best:=Interaction_Focus_3D{}
	best_dot:f32=-2
	for entity in world.typed_component_data["Interactable3D"] {
		if entity==actor || !is_enabled(world,entity) {continue}
		value,ok:=get(world,entity,Interactable3D)
		mask,_:=entity_layer_mask(world,entity)
		if !ok || !value.enabled || mask&config.target_layers==0 {continue}
		pose,has_pose:=get_transform(world,entity)
		if !has_pose {continue}
		point:=pose.position+value.offset
		// Match Rune's additive hierarchy translations.
		for parent:=world.parents[entity]; parent!=0; parent=world.parents[parent] {
			if p,exists:=get_transform(world,parent); exists {point+=p.position}
		}
		delta:=point-origin
		distance:=math.sqrt(delta.x*delta.x+delta.y*delta.y+delta.z*delta.z)
		if !finite_nonnegative(distance) || distance>config.range {continue}
		dot:f32=1
		if distance>0.00001 {dot=(delta.x*direction.x+delta.y*direction.y+delta.z*direction.z)/distance}
		if dot<min_dot || dot<best_dot {continue}
		if dot==best_dot && (distance>best.distance || (distance==best.distance && entity>best.entity)) {continue}
		if config.require_line_of_sight && distance>0.00001 {
			hit,blocked:=physics_3d_raycast(world,origin,delta,{layers=config.obstruction_layers,ignore=actor,include_sensors=false})
			if blocked {
				owner:=hit.entity
				for owner!=0 && owner!=entity {owner=world.parents[owner]}
				if owner!=entity {continue}
			}
		}
		best={entity=entity,point=point,distance=distance};best_dot=dot
	}
	return best
}

// Call once per gameplay update with the current button state and gameplay dt.
// Releasing, changing focus, losing sight/range, or editing either component
// cancels a hold. A fresh press is required, including after completion.
// Return value is the activated entity, or zero. Handle it immediately and get
// its component for a prompt; state never retains component strings.
update_interaction_3d :: proc(world:^World, state:^Interaction_State_3D, actor:Entity, origin,forward:[3]f32, down:bool, dt:f32) -> Entity {
	if state==nil {return 0}
	pressed:=down && !state.was_down
	if state.actor!=actor {state^={actor=actor};pressed=down}
	state.was_down=down
	focus:=find_interaction_3d(world,actor,origin,forward)
	target_version:=world.component_changes[{entity=focus.entity,name="Interactable3D"}].version
	actor_version:=world.component_changes[{entity=actor,name="Interactor3D"}].version
	if focus.entity!=state.focus.entity || target_version!=state.target_version || actor_version!=state.actor_version {
		state.elapsed=0;state.progress=0;state.holding=false
	}
	state.focus=focus;state.target_version=target_version;state.actor_version=actor_version
	if !down || focus.entity==0 || !finite_nonnegative(dt) {
		state.elapsed=0;state.progress=0;state.holding=false;return 0
	}
	if pressed {state.holding=true;state.elapsed=0;state.progress=0}
	if !state.holding {return 0}
	config,_:=get(world,focus.entity,Interactable3D)
	state.elapsed=min(state.elapsed+dt,config.hold_seconds)
	if config.hold_seconds>0 {state.progress=state.elapsed/config.hold_seconds}
	if state.elapsed>=config.hold_seconds {
		state.holding=false;state.progress=1;return focus.entity
	}
	return 0
}
