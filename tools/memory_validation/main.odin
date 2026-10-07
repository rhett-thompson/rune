package main

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "rune:assets"
import "rune:ecs"
import "rune:geometry"
import "rune:memory"
import rl "vendor:raylib"

Owned :: struct {label: string}
Resource :: struct {value: int}

json_value :: proc(value: $T) -> json.Value {
	bytes, err := json.marshal(value, allocator = context.temp_allocator)
	assert(err == nil)
	data: json.Value
	assert(json.unmarshal(bytes, &data, allocator = context.temp_allocator) == nil)
	return data
}

fixture :: proc(registry: ^ecs.Component_Registry, text := "authored") -> (ecs.World, ecs.Entity) {
	w := ecs.init()
	e := ecs.create_entity(&w)
	assert(ecs.set_entity_metadata(&w,e,"entity","Entity","tag",1))
	assert(ecs.add(&w,registry,e,ecs.Transform{scale={1,1,1}}))
	assert(ecs.add(&w,registry,e,ecs.TextRenderer{text=text,font="font.ttf",font_size=20,color={255,255,255,255}}))
	assert(ecs.add(&w,registry,e,Owned{label="baseline"}))
	ecs.set_scene_json(&w,json_value(struct {setting: string}{"global"}))
	ecs.capture_scene_source(&w)
	return w,e
}

main :: proc() {
	// Scratch is deliberately outside the heap being measured.
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker,context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	context.allocator = mem.tracking_allocator(&tracker)
	validate_replacement(&tracker)
	validate_compaction(&tracker)
	validate_instances()
	validate_history()
	validate_mesh_transfer()
	// Payload math can be checked without opening a graphics context.
	assert(assets.texture_bytes_estimate(rl.Texture2D{id=1,width=4,height=4,mipmaps=3,format=.UNCOMPRESSED_R8G8B8A8}) == 84)
	assert(assets.texture_bytes_estimate({}) == 0)
	assert(ecs.memory_stats(nil).map_bytes == 0)
	assert(memory.map_bytes(make(map[int]int)) == 0)
	assert(len(tracker.bad_free_array) == 0)
	assert(tracker.current_memory_allocated == 0 && len(tracker.allocation_map) == 0)
	fmt.println("PASS reclaimable JSON, failed/aliased replacement, scene compaction, authored reload baseline, stable resources, named instance cleanup, acknowledged history, memory estimates, complete cleanup")
}

validate_mesh_transfer :: proc() {
	r := ecs.init_registry(); defer ecs.destroy_registry(&r); assert(ecs.register_builtin_components(&r))
	w := ecs.init(); defer ecs.destroy(&w)
	e := ecs.create_entity(&w); assert(ecs.add(&w,&r,e,ecs.Transform{scale={1,1,1}}))
	volume := geometry.Volume{size={2,1,2},spacing=1,cells=make([]u8,4)}
	defer delete(volume.cells)
	geometry.fill_box(volume,{0,0,0},{2,1,2},1)
	colors := [2][4]u8{{},{255,255,255,255}}
	mesh,ok := geometry.surface(volume,colors[:]); assert(ok); defer geometry.destroy_mesh(&mesh)
	vertices,indices := raw_data(mesh.vertices),raw_data(mesh.indices)
	assert(!ecs.set_static_mesh_owned(&w,0,&mesh) && raw_data(mesh.vertices) == vertices)
	assert(!ecs.set_static_mesh_owned(&w,e,&mesh,&mesh,collidable=false) && raw_data(mesh.indices) == indices)
	assert(ecs.set_static_mesh_owned(&w,e,&mesh,&mesh))
	assert(len(mesh.vertices) == 0 && len(mesh.indices) == 0)
	assert(raw_data(w.static_meshes[e].data.vertices) == vertices && raw_data(w.static_meshes[e].data.indices) == indices,"vertex and index allocations must move without copying")
	borrowed := w.static_meshes[e].data
	assert(!ecs.set_static_mesh_owned(&w,e,&borrowed),"borrowed installed buffers cannot be transferred again")
	other := ecs.create_entity(&w); assert(ecs.add(&w,&r,other,ecs.Transform{scale={1,1,1}}))
	assert(!ecs.set_static_mesh_owned(&w,other,&borrowed),"a different entity cannot take another entity's buffers")
	bad: geometry.Mesh; defer geometry.destroy_mesh(&bad)
	append(&bad.vertices,..borrowed.vertices[:]); append(&bad.indices,0,0,0)
	bad_vertices := raw_data(bad.vertices)
	assert(!ecs.set_static_mesh_owned(&w,e,&bad) && raw_data(bad.vertices) == bad_vertices && len(bad.indices) == 3)
	hit,found := ecs.physics_3d_raycast(&w,{0.5,3,0.5},{0,-5,0}); assert(found && hit.entity == e && abs(hit.point[1]-1) < 0.001)
	before := ecs.memory_stats(&w).static_mesh_bytes
	assert(before > 0 && ecs.compact_scene_storage(&w))
	assert(ecs.memory_stats(&w).static_mesh_bytes == before && raw_data(w.static_meshes[e].data.vertices) == vertices)
	mesh,ok = geometry.surface(volume,colors[:]); assert(ok)
	assert(ecs.set_static_mesh_owned(&w,e,&mesh,collidable=false) && len(mesh.indices) == 0)
	_,found = ecs.physics_3d_raycast(&w,{0.5,3,0.5},{0,-5,0}); assert(!found)
	assert(ecs.destroy_entity(&w,e) && ecs.memory_stats(&w).static_mesh_bytes == 0)
}

validate_replacement :: proc(tracker: ^mem.Tracking_Allocator) {
	r := ecs.init_registry(); defer ecs.destroy_registry(&r)
	assert(ecs.register_component_type(&r,"Owned",Owned,Owned{}))
	w := ecs.init(); defer ecs.destroy(&w)
	e := ecs.create_entity(&w)
	large := strings.repeat("x",65536,context.temp_allocator)
	assert(ecs.add_component(&w,&r,e,"Owned",json_value(Owned{large})))
	assert(ecs.memory_stats(&w).owned_json_bytes >= 65536)
	previous,_ := ecs.get_component(&w,e,"Owned")
	assert(ecs.add_component(&w,&r,e,"Owned",previous),"replacement may borrow the old JSON")
	assert(!ecs.add_component(&w,&r,e,"Owned",json_value(struct {label: int}{7})))
	owned,_ := ecs.get(&w,e,Owned); assert(owned.label == large)
	assert(ecs.add(&w,&r,e,Owned{"small"}))
	live := tracker.current_memory_allocated
	for _ in 0..<1000 {
		assert(ecs.add(&w,&r,e,Owned{large}))
		assert(ecs.add(&w,&r,e,Owned{"small"}))
	}
	assert(tracker.current_memory_allocated == live,"replaced JSON and typed arenas must be released")
	assert(ecs.remove_component(&w,e,"Owned"))
	assert(ecs.memory_stats(&w).owned_json_count == 0 && ecs.memory_stats(&w).owned_json_bytes == 0)
}

validate_compaction :: proc(tracker: ^mem.Tracking_Allocator) {
	r := ecs.init_registry(); defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r) && ecs.register_component_type(&r,"Owned",Owned,Owned{}))
	w,e := fixture(&r); defer ecs.destroy(&w)
	assert(ecs.add_resource(&w,Resource{42}))
	resource,_ := ecs.resource(&w,Resource)
	assert(ecs.set(&w,e,Owned{"runtime-custom"}))
	text,_ := ecs.get(&w,e,ecs.TextRenderer)
	prefix := strings.repeat("t",256,context.temp_allocator)
	expected := fmt.tprintf("%s-999",prefix)
	for index in 0..<1000 {
		text.text = fmt.tprintf("%s-%d",prefix,index)
		assert(ecs.set(&w,e,text))
	}
	before := ecs.memory_stats(&w)
	live := tracker.current_memory_allocated
	version := ecs.change_version(&w)
	assert(ecs.compact_scene_storage(&w))
	after := ecs.memory_stats(&w)
	assert(after.retained_strings < before.retained_strings && after.scene_arena.block_bytes < before.scene_arena.block_bytes)
	assert(tracker.current_memory_allocated < live && ecs.change_version(&w) == version)
	fmt.printf("Scene arena block capacity after compaction: %d -> %d bytes\n",before.scene_arena.block_bytes,after.scene_arena.block_bytes)
	text,_ = ecs.get(&w,e,ecs.TextRenderer); assert(text.text == expected && text.font == "font.ttf")
	current_resource,_ := ecs.resource(&w,Resource); assert(current_resource == resource && resource.value == 42)
	owned,_ := ecs.get(&w,e,Owned); assert(owned.label == "runtime-custom")
	assert(w.scene_json.(json.Object)["setting"].(json.String) == "global")
	found_entity, found := ecs.find_entity_by_id(&w,"entity"); assert(found && found_entity == e)
	snapshot,_ := fixture(&r)
	assert(ecs.apply_value_snapshot(&w,&snapshot)); ecs.destroy(&snapshot)
	text,_ = ecs.get(&w,e,ecs.TextRenderer); assert(text.text == expected,"unchanged disk values preserve runtime edits after compaction")
	snapshot,_ = fixture(&r,"disk-change")
	assert(ecs.apply_value_snapshot(&w,&snapshot)); ecs.destroy(&snapshot)
	text,_ = ecs.get(&w,e,ecs.TextRenderer); assert(text.text == "disk-change")
	assert(ecs.remove_component(&w,e,"Owned") && ecs.compact_scene_storage(&w))
	assert(ecs.memory_stats(&w).owned_json_count == 2,"surviving runtime JSON remains individually owned after compaction")
	snapshot,_ = fixture(&r,"disk-change")
	assert(!ecs.apply_value_snapshot(&w,&snapshot),"compaction must retain removed authored membership in the baseline")
	ecs.destroy(&snapshot)
}

validate_instances :: proc() {
	r := ecs.init_registry(); defer ecs.destroy_registry(&r); assert(ecs.register_builtin_components(&r))
	w := ecs.init(); defer ecs.destroy(&w)
	e := ecs.create_entity(&w)
	data: json.Value
	text := `{"first":{"sound":"a.wav"},"second":{"sound":"b.wav"}}`
	assert(json.unmarshal(transmute([]u8)text,&data,allocator=context.temp_allocator) == nil)
	for _ in 0..<100 {
		assert(ecs.add_component(&w,&r,e,"AudioPlayer",data))
		assert(ecs.remove_component_instance(&w,e,"AudioPlayer","first"))
		value,found := ecs.get_component_instance(&w,e,"AudioPlayer","second")
		assert(found && value.(json.Object)["sound"].(json.String) == "b.wav")
		assert(ecs.compact_scene_storage(&w))
		assert(w.audio_players[{entity=e,name="second"}].sound == "b.wav")
		assert(ecs.remove_component_instance(&w,e,"AudioPlayer","second"))
		assert(ecs.memory_stats(&w).owned_json_bytes == 0,"the last instance reclaims its root even after compaction")
	}
	assert(len(w.owned_component_json) == 0)
	assert(ecs.set_entity_metadata(&w,e,"audio","Audio","",1))
	assert(ecs.add_component(&w,&r,e,"AudioPlayer",data))
	ecs.capture_scene_source(&w)
	runtime_text := `{"first":{"sound":"runtime.wav"},"second":{"sound":"b.wav"}}`
	runtime_data: json.Value
	assert(json.unmarshal(transmute([]u8)runtime_text,&runtime_data,allocator=context.temp_allocator) == nil)
	assert(ecs.add_component(&w,&r,e,"AudioPlayer",runtime_data))
	snapshot := ecs.init(); defer ecs.destroy(&snapshot)
	other := ecs.create_entity(&snapshot); assert(ecs.set_entity_metadata(&snapshot,other,"audio","Audio","",1))
	disk_text := `{"first":{"sound":"a.wav"},"second":{"sound":"disk.wav"}}`
	disk_data: json.Value
	assert(json.unmarshal(transmute([]u8)disk_text,&disk_data,allocator=context.temp_allocator) == nil)
	assert(ecs.add_component(&snapshot,&r,other,"AudioPlayer",disk_data))
	ecs.capture_scene_source(&snapshot)
	assert(ecs.apply_value_snapshot(&w,&snapshot))
	first,found := ecs.get_component_instance(&w,e,"AudioPlayer","first")
	assert(found && first.(json.Object)["sound"].(json.String) == "runtime.wav")
	second,second_found := ecs.get_component_instance(&w,e,"AudioPlayer","second")
	assert(second_found && second.(json.Object)["sound"].(json.String) == "disk.wav")
	assert(w.audio_players[{entity=e,name="first"}].sound == "runtime.wav")
	assert(ecs.compact_scene_storage(&w))
	root,_ := ecs.get_component(&w,e,"AudioPlayer")
	assert(root.(json.Object)["first"].(json.Object)["sound"].(json.String) == "runtime.wav")
}

validate_history :: proc() {
	r := ecs.init_registry(); defer ecs.destroy_registry(&r); assert(ecs.register_builtin_components(&r))
	w := ecs.init(); defer ecs.destroy(&w)
	for _ in 0..<1000 {
		e := ecs.create_entity(&w)
		assert(ecs.add(&w,&r,e,ecs.Transform{scale={1,1,1}}))
		cursor := ecs.change_version(&w)
		assert(ecs.destroy_entity(&w,e))
		changes,complete := ecs.changes_since_checked(&w,ecs.Transform,cursor)
		assert(complete && len(changes) == 1 && changes[0].kind == .Removed)
		assert(ecs.prune_component_changes(&w,ecs.change_version(&w)))
		_,complete = ecs.changes_since_checked(&w,ecs.Transform,cursor); assert(!complete)
		assert(len(w.component_changes) == 0)
	}
	e := ecs.create_entity(&w); assert(ecs.add(&w,&r,e,ecs.Transform{scale={1,1,1}}))
	version := ecs.change_version(&w)
	assert(ecs.prune_component_changes(&w,version) && len(w.component_changes) == 1)
	assert(!ecs.prune_component_changes(&w,version+1))
}
