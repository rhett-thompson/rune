package ecs

import "core:fmt"
import "core:slice"
import "rune:navigation"
import "rune:terrain"

// Snapshot static collision geometry. No window, asset manager or physics world
// is required. Terrain descriptors/heightmaps are read relative to project_root.
// The returned geometry is owned even on error; always destroy it.
collect_navigation_geometry_3d :: proc(world:^World,project_root:string) -> (geometry:navigation.Bake_Geometry_3D,error:string) {
	entities:=make([dynamic]Entity);defer delete(entities)
	for entity in world.entities {append(&entities,entity)}
	slice.sort(entities[:]) // Stable source order gives reproducible bakes.
	for entity in entities {
		if !is_enabled(world,entity) {continue}
		if has_component_data(world,entity,"CharacterController") || has_component_data(world,entity,"CharacterController3D") || has_component_data(world,entity,"NavAgent3D") {continue}
		if value,found:=world.terrains[entity];found && value.collision {
			t,valid:=terrain_transform(world,entity)
			if !valid {return geometry,fmt.tprintf("terrain %s has an invalid transform",world.entity_ids[entity])}
			data,_,err:=terrain.load(project_root,value.asset)
			if err!="" {return geometry,fmt.tprintf("terrain %s: %s",value.asset,err)}
			ok:=navigation.append_bake_terrain_3d(&geometry,data,t.position,t.rotation,t.scale)
			terrain.destroy(&data)
			if !ok {return geometry,"terrain geometry is invalid or exceeds bake limits"}
			continue
		}
		body,has_body:=world.rigid_bodies_3d[entity]
		if has_body && body.body_type!="static" {continue}
		t,has_transform:=world.transforms[entity]
		if !has_transform {continue}
		// Box3D boxes/spheres currently use the entity's own Transform, whereas
		// terrain uses the accumulated hierarchy. Match actual collision here.
		if box,found:=world.box_colliders[entity];found && !box.is_sensor && (has_body || box.is_static) {
			if !navigation.append_bake_box_3d(&geometry,box.size,t.position,t.rotation,t.scale) {return geometry,"invalid static box geometry"}
		}
		if sphere,found:=world.sphere_colliders[entity];found && !sphere.is_sensor && (has_body || sphere.is_static) {
			if !navigation.bake_transform_valid_3d(t.position,t.rotation,t.scale) {return geometry,"invalid static sphere transform"}
			// Circumscribed box is a conservative blocker, never a walkable roof.
			r:=sphere.radius*max(t.scale.x,t.scale.y,t.scale.z)
			if !navigation.append_bake_box_3d(&geometry,{2*r,2*r,2*r},t.position,obstacle=true) {return geometry,"invalid static sphere geometry"}
		}
	}
	return
}

bake_navigation_world_3d :: proc(world:^World,project_root:string,settings:=navigation.Default_Bake_Settings_3D) -> (navigation.Mesh_3D,navigation.Bake_Stats_3D,string) {
	geometry,error:=collect_navigation_geometry_3d(world,project_root)
	defer navigation.destroy_bake_geometry_3d(&geometry)
	if error!="" {return {},{},error}
	return navigation.bake_mesh_3d(geometry,settings)
}
