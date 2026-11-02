package ecs

// Rebuilt from current capsules once per trigger tick. A BVH avoids scanning
// every character for every zone and does not retain stale poses between ticks.
Trigger_Character_3D :: struct {
	entity: Entity,
	layers: u64,
	low, high: [3]f32,
}
Trigger_Character_Node_3D :: struct {
	low, high: [3]f32,
	first, count, left, right: int,
}

@(private)
trigger_characters_3d :: proc(world:^World) -> ([]Trigger_Character_3D, []Trigger_Character_Node_3D) {
	actors:=make([]Trigger_Character_3D,len(world.character_controllers_3d),context.temp_allocator)
	count:=0
	for entity,config in world.character_controllers_3d {
		if !character_controller_3d_ready(world,entity) {continue}
		state:=world.character_controller_states_3d[entity]
		height:=state.height if state.active else config.height
		up:=state.up; if up==([3]f32{}) {up={0,1,0}}
		feet:=world.transforms[entity].position
		a,b:=feet+up*config.radius, feet+up*(height-config.radius)
		actor:=Trigger_Character_3D{entity=entity}
		actor.layers,_=entity_layer_mask(world,entity)
		for axis in 0..<3 {
			// Include the tilted capsule's distance-query contact tolerance and
			// outward rounding at large coordinates. Exact tests still decide hits.
			margin:=0.0001+max(abs(a[axis]),abs(b[axis]))*0.000001
			actor.low[axis]=min(a[axis],b[axis])-config.radius-margin
			actor.high[axis]=max(a[axis],b[axis])+config.radius+margin
		}
		actors[count]=actor; count+=1
	}
	actors=actors[:count]
	if count==0 {return actors,nil}
	nodes:=make([]Trigger_Character_Node_3D,count*2,context.temp_allocator)
	used:=0
	build_trigger_character_tree_3d(actors,nodes,0,count,&used)
	return actors,nodes[:used]
}

@(private)
build_trigger_character_tree_3d :: proc(actors:[]Trigger_Character_3D,nodes:[]Trigger_Character_Node_3D,first,count:int,used:^int) -> int {
	index:=used^; used^+=1
	node:=&nodes[index]
	node.low=actors[first].low; node.high=actors[first].high
	for actor in actors[first+1:first+count] {for axis in 0..<3 {
		node.low[axis]=min(node.low[axis],actor.low[axis]);node.high[axis]=max(node.high[axis],actor.high[axis])
	}}
	if count<=8 {node.first=first;node.count=count;return index}
	extent:=node.high-node.low
	axis:=0; if extent.y>extent[axis] {axis=1}; if extent.z>extent[axis] {axis=2}
	midpoint:=node.low[axis]+extent[axis]*0.5
	split:=first
	for i in first..<first+count {
		actor:=actors[i]
		if actor.low[axis]+(actor.high[axis]-actor.low[axis])*0.5<midpoint {
			actors[i],actors[split]=actors[split],actors[i];split+=1
		}
	}
	// Keep recursion bounded even for coincident or extremely uneven positions.
	if split-first<count/8 || first+count-split<count/8 {split=first+count/2}
	node.left=build_trigger_character_tree_3d(actors,nodes,first,split-first,used)
	node.right=build_trigger_character_tree_3d(actors,nodes,split,first+count-split,used)
	return index
}

@(private)
collect_trigger_characters_3d :: proc(world:^World,actors:[]Trigger_Character_3D,nodes:[]Trigger_Character_Node_3D,index:int,trigger:Entity,value:Trigger3D,center,half_size:[3]f32,radius:f32) {
	node:=nodes[index]
	extent:=half_size if value.shape==.box else [3]f32{radius,radius,radius}
	low,high:=center-extent,center+extent
	for axis in 0..<3 {if node.high[axis]<low[axis] || node.low[axis]>high[axis] {return}}
	if node.count==0 {
		collect_trigger_characters_3d(world,actors,nodes,node.left,trigger,value,center,half_size,radius)
		collect_trigger_characters_3d(world,actors,nodes,node.right,trigger,value,center,half_size,radius)
		return
	}
	for actor in actors[node.first:node.first+node.count] {
		if actor.entity==trigger || actor.layers&value.layers==0 {continue}
		outside:=false
		for axis in 0..<3 {if actor.high[axis]<low[axis] || actor.low[axis]>high[axis] {outside=true;break}}
		if !outside && trigger_overlaps_character_3d(world,actor.entity,value,center,half_size,radius) {
			world.triggers_3d.scratch[{trigger=trigger,other=actor.entity}]=true
		}
	}
}
