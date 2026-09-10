package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import "rune:assets"
import "rune:ecs"
import "rune:terrain"
import "rune:scene"

fixture_serial: i64

// Distinct timestamps make polling tests deterministic on coarse filesystems.
write_fixture :: proc(path:string,data:$T) -> os.Error {
	if error := os.write_entire_file(path,data); error != nil {return error}
	fixture_serial += 1
	stamp := time.unix(1700000000+fixture_serial,0)
	return os.change_times(path,stamp,stamp)
}

parse :: proc(text:string) -> json.Value {
	value:json.Value
	assert(json.unmarshal(transmute([]u8)text,&value,allocator=context.temp_allocator)==nil)
	return value
}

add_transform :: proc(w:^ecs.World,r:^ecs.Component_Registry,e:ecs.Entity,t:ecs.Transform) -> bool {
	return ecs.add_component(w,r,e,"Transform",parse(`{}`)) && ecs.set_transform(w,e,t)
}

write_heightmap :: proc(offset: u16 = 0) {
	bytes: [17*17*2]u8
	for z in 0..<17 {for x in 0..<17 {
		v := u16(x)*1024+offset
		i := (z*17+x)*2
		bytes[i],bytes[i+1] = u8(v & 255),u8(v >> 8)
	}}
	assert(write_fixture("build/terrain-test.r16",bytes[:])==nil)
}

main :: proc() {
	validate_png()
	validate_blend()
	write_heightmap()
	assert(write_fixture("build/terrain-test.terrain.json",`{"heightmap":"build/terrain-test.r16","resolution":[17,17],"size":[16,16],"height_scale":16,"chunk_cells":8}`)==nil)
	data,_,error := terrain.load(".","build/terrain-test.terrain.json")
	assert(error=="",error)
	defer terrain.destroy(&data)
	height,inside := terrain.sample_height(data,8,8)
	assert(inside && math.abs(height-2.00003)<0.001)
	assert(terrain.normal(data,8,8)[1]>0.95,"smooth slope normal")
	_,inside = terrain.sample_height(data,-1,0)
	assert(!inside,"out-of-bounds sample")
	_,valid := ecs.terrain_from_json(parse(`{"asset":"x","unexpected":true}`)); assert(!valid)
	_,valid = ecs.terrain_from_json(parse(`{"asset":"x","friction":-1}`)); assert(!valid)
	fmt.println("PASS terrain height decoding, normals, bounds and component validation")

	manager := assets.Asset_Manager{root=".",terrains=make(map[string]assets.Terrain_Asset),retained_paths=make(map[string]string),diagnostics=assets.init_diagnostic_log()}
	defer assets.shutdown(&manager)
	r := ecs.init_registry(); defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	w := ecs.init(); defer ecs.destroy(&w)
	e := ecs.create_entity(&w)
	assert(add_transform(&w,&r,e,ecs.Transform{scale={1,1,1}}))
	t := ecs.default_terrain(); t.asset="build/terrain-test.terrain.json"
	assert(ecs.add(&w,&r,e,t))
	assert(!ecs.add_component(&w,&r,e,"RigidBody3D",parse(`{}`)),"terrain must stay static")
	ecs.sync_terrains(&w,&manager)
	hit,found := ecs.physics_3d_raycast(&w,{8,20,8},{0,-40,0})
	assert(found && hit.entity==e && hit.component=="Terrain" && math.abs(hit.point[1]-height)<0.001,"native triangles match rendering")
	// A moving character crosses a render chunk boundary and triangle edges.
	p := ecs.create_entity(&w)
	assert(add_transform(&w,&r,p,ecs.Transform{position={6,4,8},scale={1,1,1}}))
	assert(ecs.add(&w,&r,p,ecs.default_character_controller_3d()))
	for _ in 0..<120 {ecs.physics_3d_update(&w,1.0/60)}
	motor,_ := ecs.get_character_controller_3d_state(&w,p); assert(motor.grounded)
	ecs.character_controller_3d_move(&w,p,{1,0})
	for _ in 0..<60 {ecs.physics_3d_update(&w,1.0/60)}
	pose,_ := ecs.get_transform(&w,p)
	motor,_ = ecs.get_character_controller_3d_state(&w,p)
	assert(pose.position[0]>10 && motor.grounded,"walk uphill across chunk seam")
	fmt.println("PASS native terrain raycast and capsule traversal across chunk seams")
	ball := ecs.create_entity(&w)
	assert(add_transform(&w,&r,ball,{position={12,8,12},scale={1,1,1}}))
	assert(ecs.add_component(&w,&r,ball,"SphereCollider",parse(`{"radius":0.4}`)))
	assert(ecs.add_component(&w,&r,ball,"RigidBody3D",parse(`{}`)))
	for _ in 0..<120 {ecs.physics_3d_update(&w,1.0/60)}
	ball_pose,_ := ecs.get_transform(&w,ball)
	ball_ground,ball_inside := terrain.sample_height(data,ball_pose.position[0],ball_pose.position[2])
	assert(ball_inside && ball_pose.position[1]>ball_ground+0.3 && ball_pose.position[1]<ball_ground+0.6,"dynamic sphere rests on terrain")
	assert(ecs.destroy_entity(&w,ball))
	fmt.println("PASS dynamic rigid body terrain contact")

	assert(ecs.set_enabled(&w,e,false))
	_,found = ecs.physics_3d_raycast(&w,{8,20,8},{0,-40,0}); assert(!found)
	assert(ecs.set_enabled(&w,e,true))
	_,found = ecs.physics_3d_raycast(&w,{8,20,8},{0,-40,0}); assert(found)
	t.collision=false; assert(ecs.set(&w,e,t))
	_,found = ecs.physics_3d_raycast(&w,{8,20,8},{0,-40,0}); assert(!found)
	t.collision=true; assert(ecs.set(&w,e,t))
	parent := ecs.create_entity(&w)
	assert(add_transform(&w,&r,parent,ecs.Transform{position={0,3,0},scale={1,2,1}}))
	assert(ecs.set_parent(&w,e,parent))
	hit,found = ecs.physics_3d_raycast(&w,{8,20,8},{0,-40,0})
	assert(found && math.abs(hit.point[1]-(3+height*2))<0.001,"hierarchy transform")
	assert(ecs.set_transform(&w,parent,ecs.Transform{position={0,5,0},scale={1,1,1}}))
	hit,found = ecs.physics_3d_raycast(&w,{8,20,8},{0,-40,0})
	assert(found && math.abs(hit.point[1]-(5+height))<0.001,"parent edits reach native queries")
	// Parent and child edits can cancel out in world space. The native pose
	// must still remain composed, rather than taking the child's local pose.
	assert(ecs.set_transform(&w,e,{position={0,2,0},scale={1,1,1}}))
	assert(ecs.set_transform(&w,parent,{position={0,3,0},scale={1,1,1}}))
	hit,found = ecs.physics_3d_raycast(&w,{8,20,8},{0,-40,0})
	assert(found && math.abs(hit.point[1]-(5+height))<0.001,"canceling hierarchy edits retain composed pose")
	fmt.println("PASS activation, collision toggle and hierarchy edits")

	_,old_revision,_ := ecs.terrain_runtime(&w,e)
	assert(write_fixture("build/terrain-test.r16","broken")==nil)
	assets.refresh_terrains(&manager)
	ecs.sync_terrains(&w,&manager)
	_,revision,_ := ecs.terrain_runtime(&w,e)
	assert(revision==old_revision,"bad reload preserves geometry")
	hit,found = ecs.physics_3d_raycast(&w,{8,20,8},{0,-40,0})
	assert(found && math.abs(hit.point[1]-(5+height))<0.001,"bad reload preserves collision")
	write_heightmap(4096)
	assets.refresh_terrains(&manager)
	ecs.sync_terrains(&w,&manager)
	_,revision,_ = ecs.terrain_runtime(&w,e)
	assert(revision>old_revision,"repaired heightmap retries")
	hit,found = ecs.physics_3d_raycast(&w,{8,20,8},{0,-40,0})
	assert(found && math.abs(hit.point[1]-(6+height))<0.001,"repaired collision updated")
	fmt.println("PASS invalid reload retention and repaired heightmap recovery")
	assert(ecs.remove_component(&w,e,"Terrain"))
	_,found = ecs.physics_3d_raycast(&w,{8,20,8},{0,-40,0}); assert(!found)
	_,_,found = ecs.terrain_runtime(&w,e); assert(!found)
	fmt.println("PASS terrain removal and resource lifetime")
	validate_snapshot(&r,&manager)
	for arg in os.args[1:] {if arg=="--runtime" {validate_runtime()}}
}

validate_blend :: proc() {
	path := "build/terrain-blend.terrain.json"
	base :: `{"heightmap":"tools/terrain_validation/fixtures/precision.png","resolution":[2,2],"blend":`
	for blend in ([]string{
		`{"grass":"grass.png"}`,
		`{"grass":12}`,
		`{"unknown":true}`,
		`{"dirt_height":[2,1]}`,
		`{"dirt_height":[1,1]}`,
		`{"rock_slope":[0,91]}`,
		`{"rock_slope":[20]}`,
		`{"noise_scale":0}`,
		`{"noise_strength":1.1}`,
		`null`,
	}) {
		assert(write_fixture(path,fmt.tprint(base,blend,"}"))==nil)
		data,_,error := terrain.load(".",path)
		assert(error!="","reject malformed or incomplete blend")
		terrain.destroy(&data)
	}
	assert(write_fixture(path,fmt.tprint(base,`{"grass":"grass.png","dirt":"dirt.png","rock":"rock.png"}}`))==nil)
	data,_,error := terrain.load(".",path)
	assert(error=="",error)
	assert(data.description.blend.dirt_height==[2]f32{3,9},"omitted blend fields retain defaults")
	copy := terrain.clone(data)
	terrain.destroy(&data)
	assert(copy.description.blend.grass=="grass.png" && copy.description.blend.dirt=="dirt.png" && copy.description.blend.rock=="rock.png","cloned blend paths outlive source")
	terrain.destroy(&copy)
	assert(write_fixture(path,fmt.tprint(base,`{}}`))==nil)
	data,_,error = terrain.load(".",path)
	assert(error=="" && !terrain.blend_enabled(data.description.blend),"empty blend disables layers")
	terrain.destroy(&data)
	fmt.println("PASS terrain blend validation, defaults and owned layer paths")
}

validate_png :: proc() {
	for name,index in ([]string{"precision.png","eight-bit.png"}) {
		descriptor,_ := strings.concatenate({`{"$schema":"ignored","heightmap":"tools/terrain_validation/fixtures/`,name,`","resolution":[2,2],"size":[1,1],"height_scale":65535}`},context.temp_allocator)
		assert(write_fixture("build/terrain-png.terrain.json",descriptor)==nil)
		data,_,error := terrain.load(".","build/terrain-png.terrain.json")
		assert(error=="",error)
		expected := f32(1) if index==0 else f32(257)
		assert(data.heights[0]==0 && data.heights[1]==expected && data.heights[3]==65535,"preserve full PNG precision")
		// A non-planar quad distinguishes triangle interpolation from bilinear.
		data.heights[0],data.heights[1],data.heights[2],data.heights[3]=0,0,0,4
		h,_ := terrain.sample_height(data,0.25,0.25); assert(h==0)
		h,_ = terrain.sample_height(data,0.75,0.75); assert(math.abs(h-2)<0.001)
		terrain.destroy(&data)
	}
	for descriptor in ([]string{
		`{"heightmap":"tools/terrain_validation/fixtures/color.png","resolution":[2,2]}`,
		`{"heightmap":"tools/terrain_validation/fixtures/precision.png","resolution":[3,2]}`,
		`{"heightmap":"tools/terrain_validation/fixtures/precision.png","resolution":[2,2],"unknown":true}`,
		`{"heightmap":"tools/terrain_validation/fixtures/precision.png","resolution":[2,2],"chunk_cells":7}`,
		`{"heightmap":"tools/terrain_validation/fixtures/precision.png","resolution":[2,2],"size":[0,1]}`,
	}) {
		assert(write_fixture("build/terrain-png.terrain.json",descriptor)==nil)
		data,_,error := terrain.load(".","build/terrain-png.terrain.json")
		assert(error!="","reject invalid PNG or descriptor")
		terrain.destroy(&data)
	}
	fmt.println("PASS 8/16-bit PNG decoding, exact triangle interpolation, malformed descriptor rejection")
}

validate_snapshot :: proc(r:^ecs.Component_Registry,manager:^assets.Asset_Manager) {
	path := "build/terrain-snapshot.scene.json"
	assert(write_fixture(path,`{"name":"Terrain","entities":[{"id":"ground","components":{"Transform":{},"Terrain":{"asset":"build/terrain-test.terrain.json"}}}]}`)==nil)
	w,ok := scene.load(path,r); assert(ok)
	defer ecs.destroy(&w)
	e,_ := ecs.find_entity_by_id(&w,"ground")
	ecs.sync_terrains(&w,manager)
	_,revision,_ := ecs.terrain_runtime(&w,e)
	assert(write_fixture(path,`{"name":"Terrain","entities":[{"id":"ground","components":{"Transform":{},"Terrain":{"asset":"build/terrain-test.terrain.json","shadows":false}}}]}`)==nil)
	snapshot,loaded := scene.load(path,r); assert(loaded)
	assert(ecs.apply_value_snapshot(&w,&snapshot))
	ecs.destroy(&snapshot)
	t,_ := ecs.get(&w,e,ecs.Terrain)
	assert(t.asset=="build/terrain-test.terrain.json" && !t.shadows,"retain component strings across snapshots")
	ecs.sync_terrains(&w,manager)
	_,current,_ := ecs.terrain_runtime(&w,e)
	assert(current==revision,"appearance-only edits preserve geometry")
	t.asset="build/nonexistent-terrain.terrain.json"
	assert(ecs.set(&w,e,t)); ecs.sync_terrains(&w,manager)
	_,current,_=ecs.terrain_runtime(&w,e); assert(current==revision,"missing replacement preserves working geometry")
	_,hit := ecs.physics_3d_raycast(&w,{8,20,8},{0,-40,0}); assert(hit,"missing replacement preserves collision")
	assert(ecs.destroy_entity(&w,e))
	_,_,found := ecs.terrain_runtime(&w,e); assert(!found)
	fmt.println("PASS snapshot ownership, appearance edits, missing replacement and entity destruction")
}
