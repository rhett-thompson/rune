package ecs

import "core:encoding/json"
import "core:math"
import "core:slice"

Trigger_Shape_3D :: enum {box, sphere}
// Query-only volumes: no collider/body is required and they never block motion.
// Boxes stay world-axis aligned. Dimensions inherit absolute hierarchy scale;
// spheres use its largest axis. Offset is in unscaled world units.
Trigger3D :: struct {
	shape: Trigger_Shape_3D,
	size, offset: [3]f32,
	radius: f32,
	layers: u64,
	enabled, include_sensors: bool,
}
Default_Trigger_3D :: Trigger3D{size={2,2,2},radius=1,layers=~u64(0),enabled=true}
trigger_3d_valid :: proc(value:Trigger3D) -> bool {
	if value.shape!=.box && value.shape!=.sphere {return false}
	for n in value.size {if !finite_nonnegative(n) || n==0 {return false}}
	return physics_query_vector_valid(value.offset) && finite_nonnegative(value.radius) && value.radius>0
}
trigger_3d_from_json :: proc(data:json.Value) -> (Trigger3D,bool) {
	value:=Default_Trigger_3D
	if !json_shape_matches_type(data,Trigger3D) {return {},false}
	object,_:=data.(json.Object)
	if shape,exists:=object["shape"]; exists {
		// Odin serializes typed enum values numerically; authored names are
		// accepted too. Unknown names must not silently decode to zero/box.
		#partial switch name in shape {
		case json.String: if name!="box" && name!="sphere" {return {},false}
		case json.Integer: if name!=0 && name!=1 {return {},false}
		case json.Float: if name!=0 && name!=1 {return {},false}
		case: return {},false
		}
	}
	bytes,err:=json.marshal(data,allocator=context.temp_allocator)
	if err!=nil || json.unmarshal(bytes,&value,allocator=context.temp_allocator)!=nil {return {},false}
	return value,trigger_3d_valid(value)
}

Trigger_Event_Kind_3D :: enum {Enter, Stay, Exit}
Trigger_Pair_3D :: struct {trigger,other:Entity}
Trigger_Event_3D :: struct {trigger,other:Entity,kind:Trigger_Event_Kind_3D}
Trigger_Runtime_3D :: struct {
	overlaps, scratch: map[Trigger_Pair_3D]bool,
	events: [dynamic]Trigger_Event_3D,
}
destroy_triggers_3d :: proc(world:^World) {
	delete(world.triggers_3d.overlaps);delete(world.triggers_3d.scratch);delete(world.triggers_3d.events)
	world.triggers_3d={}
}
// Quietly discard transient membership; the next update produces fresh enters.
reset_triggers_3d :: proc(world:^World) {
	clear(&world.triggers_3d.overlaps);clear(&world.triggers_3d.scratch);clear(&world.triggers_3d.events)
}
// Borrowed until the next trigger update/reset or World destruction. Consume in
// post_physics; each fixed tick produces Enter OR Stay for each current pair.
// Exit may contain a destroyed entity handle: check is_alive before using it.
trigger_events_3d :: proc(world:^World) -> []Trigger_Event_3D {return world.triggers_3d.events[:]}
trigger_contains_3d :: proc(world:^World,trigger,other:Entity) -> bool {
	return world.triggers_3d.overlaps[{trigger=trigger,other=other}]
}

trigger_geometry_3d :: proc(world:^World,entity:Entity,value:Trigger3D) -> (center,half_size:[3]f32,radius:f32,ok:bool) {
	if !has_component_data(world,entity,"Transform") {return}
	scale:=[3]f32{1,1,1}
	for current:=entity; current!=0; current=world.parents[current] {
		if pose,found:=get_transform(world,current); found {center+=pose.position;scale*=pose.scale}
	}
	for &axis in scale {axis=math.abs(axis)}
	center+=value.offset;half_size=value.size*scale*0.5;radius=value.radius*max(scale.x,scale.y,scale.z)
	if !physics_query_vector_valid(center) || !physics_query_vector_valid(half_size) || !finite_nonnegative(radius) {return}
	ok=half_size.x>0 && half_size.y>0 && half_size.z>0 && radius>0
	return
}

// Capsule versus AABB/sphere, including its rounded caps and crouch height.
// CharacterController3D is a query motor, absent from native collider queries.
trigger_overlaps_character_3d :: proc(world:^World,actor:Entity,value:Trigger3D,center,half_size:[3]f32,radius:f32) -> bool {
	if !character_controller_3d_ready(world,actor) {return false}
	config:=world.character_controllers_3d[actor]
	state:=world.character_controller_states_3d[actor]
	height:=state.height if state.active else config.height
	feet:=world.transforms[actor].position
	low,high:=feet.y+config.radius,feet.y+height-config.radius
	delta:=[3]f32{math.abs(feet.x-center.x),max(low-center.y,center.y-high,0),math.abs(feet.z-center.z)}
	combined_radius:=config.radius
	if value.shape==.box {
		for &axis,i in delta {axis=max(0,axis-half_size[i])}
	} else {combined_radius+=radius}
	return delta.x*delta.x+delta.y*delta.y+delta.z*delta.z<=combined_radius*combined_radius
}

// Called by the engine after 3D physics, before post_physics callbacks. Headless
// hosts call this explicitly. Detection samples overlaps, not swept trajectories.
update_triggers_3d :: proc(world:^World) {
	runtime:=&world.triggers_3d
	clear(&runtime.events)
	if len(world.typed_component_data["Trigger3D"])==0 && len(runtime.overlaps)==0 {return}
	if runtime.overlaps==nil {runtime.overlaps=make(map[Trigger_Pair_3D]bool)}
	if runtime.scratch==nil {runtime.scratch=make(map[Trigger_Pair_3D]bool)}
	clear(&runtime.scratch)
	for trigger in world.typed_component_data["Trigger3D"] {
		value,_:=get(world,trigger,Trigger3D)
		if !value.enabled || !is_enabled(world,trigger) || value.layers==0 {continue}
		center,half_size,radius,valid:=trigger_geometry_3d(world,trigger,value)
		if !valid {continue}
		filter:=Physics_Query_Filter{layers=value.layers,ignore=trigger,include_sensors=value.include_sensors}
		hits:[]Entity
		if value.shape==.box {hits=physics_3d_overlap_box(world,center,half_size,filter)}
		else {hits=physics_3d_overlap_sphere(world,center,radius,filter)}
		for other in hits {runtime.scratch[{trigger=trigger,other=other}]=true}
		for actor in world.character_controllers_3d {
			layers,_:=entity_layer_mask(world,actor)
			if actor==trigger || layers&value.layers==0 {continue}
			if trigger_overlaps_character_3d(world,actor,value,center,half_size,radius) {
				runtime.scratch[{trigger=trigger,other=actor}]=true
			}
		}
	}
	for pair in runtime.scratch {
		kind:=Trigger_Event_Kind_3D.Stay if runtime.overlaps[pair] else Trigger_Event_Kind_3D.Enter
		append(&runtime.events,Trigger_Event_3D{trigger=pair.trigger,other=pair.other,kind=kind})
	}
	for pair in runtime.overlaps {
		if !runtime.scratch[pair] {append(&runtime.events,Trigger_Event_3D{trigger=pair.trigger,other=pair.other,kind=.Exit})}
	}
	runtime.overlaps,runtime.scratch=runtime.scratch,runtime.overlaps
	slice.sort_by(runtime.events[:],proc(a,b:Trigger_Event_3D)->bool {
		return a.trigger<b.trigger || (a.trigger==b.trigger && a.other<b.other)
	})
}
