package ecs

import "core:math"
import "core:encoding/json"
import "core:strings"
import "rune:assets"
import "rune:navigation"

// The navmesh asset uses world-space coordinates; Transform does not move it.
NavMesh3D :: struct {asset:string}
NavAgent3D :: struct {
	mesh: Entity_Ref,
	speed,radius,height,max_slope,max_projection: f32,
	arrival_distance,repath_interval: f32,
	// Otherwise the agent moves its root Transform along the surface directly.
	drive_controller: bool,
}
default_nav_agent_3d :: proc() -> NavAgent3D {
	return {speed=3,radius=0.3,height=1.8,max_slope=45,max_projection=1,arrival_distance=0.12,repath_interval=0.5}
}
nav_agent_3d_valid :: proc(v:NavAgent3D) -> bool {
	return v.mesh.id!="" && finite_nonnegative(v.speed) && finite_nonnegative(v.radius) &&
		finite_nonnegative(v.height) && v.height>0 && finite_nonnegative(v.max_slope) && v.max_slope<89 &&
		finite_nonnegative(v.max_projection) && finite_nonnegative(v.arrival_distance) &&
		v.arrival_distance>0 && finite_nonnegative(v.repath_interval) && v.repath_interval>0
}
nav_component_3d_from_json :: proc(data:json.Value,$T:typeid) -> (T,bool) {
	result:T
	when T==NavAgent3D {result=default_nav_agent_3d()}
	if !json_shape_matches_type(data,T) {return {},false}
	bytes,err:=json.marshal(data,allocator=context.temp_allocator)
	if err!=nil || json.unmarshal(bytes,&result,allocator=context.temp_allocator)!=nil {return {},false}
	return result,component_value_valid(result)
}
Nav_Status_3D :: enum {Idle,Pending,Moving,Arrived,No_Path,Unavailable,Disabled}
Nav_Agent_State_3D :: struct {
	status: Nav_Status_3D,
	path_status: navigation.Path_Status_3D,
	has_target: bool,
	target,desired_velocity: [3]f32,
	// Borrowed until the next navigation update, target change, or destruction.
	path: [][3]f32,
	next_point: int,
}
Nav_Agent_Runtime_3D :: struct {
	state: Nav_Agent_State_3D,
	path: navigation.Path_3D,
	mesh: Entity,
	revision:u64,
	config_version:u64,
	repath_remaining:f32,
	last_position:[3]f32,
	position_valid:bool,
}
Nav_Mesh_Runtime_3D :: struct {
	mesh:navigation.Mesh_3D,
	source:string,
	asset_revision,revision:u64,
}
Navigation_Runtime_3D :: struct {
	meshes:map[Entity]Nav_Mesh_Runtime_3D,
	agents:map[Entity]Nav_Agent_Runtime_3D,
	revision:u64,
}
ensure_navigation_3d :: proc(world:^World) {
	if world.navigation_3d.meshes==nil {world.navigation_3d.meshes=make(map[Entity]Nav_Mesh_Runtime_3D)}
	if world.navigation_3d.agents==nil {world.navigation_3d.agents=make(map[Entity]Nav_Agent_Runtime_3D)}
}
remove_navigation_agent_3d :: proc(world:^World,entity:Entity) {
	if runtime,found:=world.navigation_3d.agents[entity]; found {
		character_controller_3d_move(world,entity,{})
		navigation.destroy_path_3d(&runtime.path); delete_key(&world.navigation_3d.agents,entity)
	}
}
remove_navigation_mesh_3d :: proc(world:^World,entity:Entity) {
	if runtime,found:=world.navigation_3d.meshes[entity]; found {
		navigation.destroy_mesh_3d(&runtime.mesh); delete(runtime.source); delete_key(&world.navigation_3d.meshes,entity)
	}
}
destroy_navigation_3d :: proc(world:^World) {
	for _,&runtime in world.navigation_3d.agents {navigation.destroy_path_3d(&runtime.path)}
	for _,&runtime in world.navigation_3d.meshes {navigation.destroy_mesh_3d(&runtime.mesh); delete(runtime.source)}
	delete(world.navigation_3d.agents); delete(world.navigation_3d.meshes); world.navigation_3d={}
}

// Sync after asset refresh, before simulation/start/restore callbacks.
sync_navigation_3d :: proc(world:^World,manager:^assets.Asset_Manager) {
	for entity in entities_with_component(world,"NavMesh3D",include_disabled=true) {
		config,_:=get(world,entity,NavMesh3D)
		mesh,revision,loaded:=assets.navmesh_data(manager,config.asset)
		if !loaded {continue}
		ensure_navigation_3d(world)
		old,found:=world.navigation_3d.meshes[entity]
		if found && old.source==config.asset && old.asset_revision==revision {continue}
		copy_mesh:=navigation.Mesh_3D{agent_radius=mesh.agent_radius,agent_height=mesh.agent_height,
			vertices=make([][3]f32,len(mesh.vertices)),triangles=make([]navigation.Triangle_3D,len(mesh.triangles))}
		copy(copy_mesh.vertices,mesh.vertices); copy(copy_mesh.triangles,mesh.triangles)
		remove_navigation_mesh_3d(world,entity)
		world.navigation_3d.revision+=1
		world.navigation_3d.meshes[entity]={mesh=copy_mesh,source=strings.clone(config.asset) or_else "",asset_revision=revision,revision=world.navigation_3d.revision}
	}
}
// The mesh is borrowed read-only. Use the blocking API rather than mutating it.
navigation_mesh_3d :: proc(world:^World,entity:Entity) -> (navigation.Mesh_3D,bool) {
	config,has_config:=get(world,entity,NavMesh3D)
	runtime,found:=world.navigation_3d.meshes[entity]
	return runtime.mesh,found && has_config && runtime.source==config.asset && is_enabled(world,entity)
}
set_navigation_triangle_blocked_3d :: proc(world:^World,mesh_entity:Entity,triangle:i32,blocked:bool) -> bool {
	runtime,found:=world.navigation_3d.meshes[mesh_entity]
	if !found || triangle<0 || int(triangle)>=len(runtime.mesh.triangles) {return false}
	if runtime.mesh.triangles[triangle].blocked==blocked {return true}
	runtime.mesh.triangles[triangle].blocked=blocked
	world.navigation_3d.revision+=1; runtime.revision=world.navigation_3d.revision
	world.navigation_3d.meshes[mesh_entity]=runtime
	return true
}
set_navigation_target_3d :: proc(world:^World,entity:Entity,target:[3]f32) -> bool {
	if !is_alive(world,entity) || !has_component_data(world,entity,"NavAgent3D") || !navigation.finite_point_3d(target) {return false}
	ensure_navigation_3d(world)
	runtime:=world.navigation_3d.agents[entity]
	if runtime.state.has_target && runtime.state.target==target {return true}
	navigation.destroy_path_3d(&runtime.path)
	runtime.state=Nav_Agent_State_3D{status=.Pending,has_target=true,target=target}
	runtime.repath_remaining=0; runtime.revision=0
	world.navigation_3d.agents[entity]=runtime
	return true
}
stop_navigation_3d :: proc(world:^World,entity:Entity) -> bool {
	if !has_component_data(world,entity,"NavAgent3D") {return false}
	remove_navigation_agent_3d(world,entity)
	return true
}
get_navigation_state_3d :: proc(world:^World,entity:Entity) -> (Nav_Agent_State_3D,bool) {
	if !has_component_data(world,entity,"NavAgent3D") {return {},false}
	return world.navigation_3d.agents[entity].state,true
}

// Run before physics on each fixed step. Game systems may set targets first.
update_navigation_3d :: proc(world:^World,dt:f32) {
	if !finite_nonnegative(dt) || dt<=0 {return}
	for entity,&runtime in world.navigation_3d.agents {
		config,found:=get(world,entity,NavAgent3D)
		if !found {continue}
		runtime.state.desired_velocity={}
		if config.drive_controller {character_controller_3d_move(world,entity,{})}
		if !runtime.state.has_target {continue}
		if !is_enabled(world,entity) {runtime.state.status=.Disabled; runtime.revision=0; continue}
		transform,has_transform:=get_transform(world,entity)
		mesh_entity,has_mesh:=resolve_entity_ref(world,config.mesh)
		mesh,mesh_ready:=navigation_mesh_3d(world,mesh_entity)
		parent,has_parent:=get_parent(world,entity)
		if !has_transform || !has_mesh || !mesh_ready || has_parent || parent!=Entity(0) || transform.scale!=([3]f32{1,1,1}) ||
		   has_component_data(world,entity,"RigidBody3D") || (!config.drive_controller && has_component_data(world,entity,"CharacterController3D")) {
			runtime.state.status=.Unavailable; runtime.revision=0; continue
		}
		if config.drive_controller {
			motor,ok:=get_character_controller_3d(world,entity)
			if !ok || !character_controller_3d_ready(world,entity) || config.radius<motor.radius || config.height<motor.height || config.max_slope>motor.max_slope_angle {
				runtime.state.status=.Unavailable; runtime.revision=0; continue
			}
		}
		mesh_revision:=world.navigation_3d.meshes[mesh_entity].revision
		// A game-owned teleport must not continue an old corridor through walls
		// until the periodic repath timer expires. Motors legitimately move
		// between navigation updates, so allow their ordinary fixed-step travel.
		teleport_distance:=max(config.max_projection,config.speed*dt*4+0.25) if config.drive_controller else f32(0.001)
		if runtime.position_valid && navigation.distance_3d(runtime.last_position,transform.position)>teleport_distance {runtime.revision=0}
		runtime.last_position=transform.position;runtime.position_valid=true
		config_version:=world.component_changes[Component_Change_Key{entity=entity,name="NavAgent3D"}].version
		runtime.repath_remaining-=dt
		if runtime.repath_remaining<=0 || runtime.revision!=mesh_revision || runtime.mesh!=mesh_entity || runtime.config_version!=config_version {
			navigation.destroy_path_3d(&runtime.path)
			runtime.path=navigation.find_path_3d(&mesh,transform.position,runtime.state.target,
				{radius=config.radius,height=config.height,max_slope=config.max_slope,max_projection=config.max_projection})
			runtime.state.path=runtime.path.points; runtime.state.path_status=runtime.path.status; runtime.state.next_point=0
			runtime.repath_remaining=config.repath_interval; runtime.revision=mesh_revision; runtime.mesh=mesh_entity; runtime.config_version=config_version
		}
		if runtime.path.status!=.Complete {runtime.state.status=.No_Path; continue}
		runtime.state.status=.Moving
		remaining:=config.speed*dt
		for runtime.state.next_point<len(runtime.path.points) {
			next:=runtime.path.points[runtime.state.next_point]
			delta:=next-transform.position
			distance:=navigation.length_3d(delta)
			last:=runtime.state.next_point==len(runtime.path.points)-1
			// Transform motion reaches every portal exactly; skipping corners by
			// arrival radius could cut outside the mesh. Only the final goal has tolerance.
			if distance<=1e-5 || (last && distance<=config.arrival_distance) ||
			   (config.drive_controller && navigation.length_3d({delta.x,0,delta.z})<=config.arrival_distance && abs(delta.y)<=max(config.arrival_distance,0.25)) {
				runtime.state.next_point+=1; continue
			}
			if config.drive_controller {
				motor,_:=get_character_controller_3d(world,entity)
				horizontal:=math.sqrt(delta.x*delta.x+delta.z*delta.z)
				if horizontal>1e-5 && motor.move_speed>0 {
					speed:=min(config.speed,min(motor.move_speed,horizontal/dt))
					direction:=[2]f32{delta.x/horizontal,delta.z/horizontal}
					character_controller_3d_move(world,entity,direction*(speed/motor.move_speed))
					runtime.state.desired_velocity={direction.x*speed,0,direction.y*speed}
				}
				break
			}
			if remaining<=0 {break}
			travel:=min(remaining,distance)
			transform.position+=delta*(travel/distance); remaining-=travel
			runtime.state.desired_velocity=delta*(config.speed/distance)
			if travel<distance {break}; runtime.state.next_point+=1
		}
		if !config.drive_controller {set_transform(world,entity,transform);runtime.last_position=transform.position}
		if runtime.state.next_point>=len(runtime.path.points) {runtime.state.status=.Arrived; runtime.state.desired_velocity={}}
	}
}
