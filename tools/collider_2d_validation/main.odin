package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "rune:ecs"
import "rune:gizmos"
import "rune:scene"
import "rune:validation"
import rl "vendor:raylib"

parse :: proc(text: string) -> json.Value {
	value: json.Value
	assert(json.unmarshal(transmute([]u8)text, &value, allocator = context.temp_allocator) == nil)
	return value
}
add :: proc(w: ^ecs.World, r: ^ecs.Component_Registry, e: ecs.Entity, name, text: string) {
	assert(ecs.add_component(w, r, e, name, parse(text)), name)
}
body :: proc(w: ^ecs.World, r: ^ecs.Component_Registry) -> ecs.Entity {
	e := ecs.create_entity(w)
	add(w, r, e, "Transform", `{}`)
	return e
}
near :: proc(a, b: f32) -> bool {return math.abs(a-b) < 0.02}

validate_data :: proc(r: ^ecs.Component_Registry) {
	w := ecs.init()
	defer ecs.destroy(&w)
	e := body(&w, r)
	capsule := ecs.default_capsule_collider_2d()
	assert(ecs.add(&w, r, e, capsule))
	assert(ecs.add(&w, r, e, ecs.BoxCollider2D{size = {2,4}, offset = {5,2}}))
	assert(ecs.add(&w, r, e, ecs.CircleCollider2D{radius = 2, offset = {-5,2}}))
	capsule.axis, capsule.offset = .horizontal, {3,-6}
	assert(ecs.set(&w, e, capsule))
	data, ok := ecs.runtime_component_json(&w, e, "CapsuleCollider2D")
	assert(ok && data.(json.Object)["axis"].(json.String) == "horizontal")
	assert(ecs.add_component(&w, r, e, "CapsuleCollider2D", data))
	actual, found := ecs.get(&w, e, ecs.CapsuleCollider2D)
	assert(found && actual == capsule)
	for invalid in ([]string{`{"radius":0}`, `{"height":15}`, `{"axis":"diagonal"}`, `{"offset":[0]}`, `{"offset":[0,"a"]}`, `{"is_sensor":1}`, `{"unknown":1}`}) {
		assert(!ecs.add_component(&w, r, e, "CapsuleCollider2D", parse(invalid)), invalid)
	}
	for name in ([]string{"BoxCollider2D", "CircleCollider2D"}) {
		assert(!ecs.add_component(&w, r, e, name, parse(`{"offset":[0,"x"]}`)))
		value, valid := ecs.runtime_component_json(&w, e, name)
		assert(valid && ecs.add_component(&w, r, e, name, value))
	}
	capsule.offset[0] = math.inf_f32(1)
	assert(!ecs.set(&w, e, capsule))
	assert(!ecs.set(&w, e, ecs.BoxCollider2D{size={2,2},offset={math.nan_f32(),0}}))
	assert(!ecs.set(&w, e, ecs.CircleCollider2D{radius=2,offset={0,math.inf_f32(1)}}))
}

validate_offsets :: proc(r: ^ecs.Component_Registry) {
	for moving in ([]bool{false, true}) {
		w := ecs.init()
		defer ecs.destroy(&w)
		e := body(&w, r)
		if moving {add(&w, r, e, "RigidBody2D", `{"gravity_scale":0}`)}
		add(&w, r, e, "BoxCollider2D", `{"size":[2,4],"offset":[5,0]}`)
		add(&w, r, e, "CircleCollider2D", `{"radius":1,"offset":[10,0]}`)
		add(&w, r, e, "CapsuleCollider2D", `{"radius":1,"height":6,"offset":[15,0]}`)
		component_names := [3]string{"BoxCollider2D","CircleCollider2D","CapsuleCollider2D"}
		for x, i in ([3]f32{5,10,15}) {
			hit, found := ecs.physics_2d_raycast(&w, {x,-10}, {0,20})
			assert(found && hit.entity == e)
			assert(hit.component == component_names[i])
		}
		assert(len(w.physics_2d.shapes) == 3 && len(w.box2d_bodies) == 1, "compound shapes share one body")
		assert(len(ecs.physics_2d_overlap_circle(&w, {10,0}, 20)) == 1, "deduplicate compound overlap results")
		assert(len(ecs.physics_2d_overlap_box(&w, {0,0}, {1,1})) == 0, "entity origin is not the collider center")
		transform, _ := ecs.get_transform(&w, e)
		transform.position = {100,20,0}
		transform.scale = {-2,3,1}
		assert(ecs.set_transform(&w, e, transform))
		expected_heights := [3]f32{14,17,11}
		for x, i in ([3]f32{90,80,70}) {
			hit, found := ecs.physics_2d_raycast(&w, {x,0}, {0,40})
			assert(found && hit.entity == e)
			expected_y := expected_heights[i]
			assert(near(hit.point[1], expected_y), "signed offset scale, positive dimensions, conservative radius scale")
		}
		assert(ecs.set_runtime_field(&w, r, e, "CapsuleCollider2D", "offset", parse(`[20,0]`)))
		_, missing := ecs.physics_2d_raycast(&w, {70,0}, {0,40})
		assert(!missing, "runtime edits rebuild the old geometry")
		hit, found := ecs.physics_2d_raycast(&w, {60,0}, {0,40})
		assert(found && hit.component == "CapsuleCollider2D")
		assert(ecs.remove_component(&w, e, "BoxCollider2D"))
		assert(len(ecs.physics_2d_overlap_circle(&w, {90,20}, 1)) == 0)
		assert(len(w.physics_2d.shapes) == 2, "removing one shape preserves the other two")
		ecs.set_enabled(&w, e, false)
		assert(len(ecs.physics_2d_overlap_circle(&w, {60,20}, 50)) == 0)
		ecs.set_enabled(&w, e, true)
		assert(len(ecs.physics_2d_overlap_circle(&w, {60,20}, 50)) == 1)
		ecs.destroy_entity(&w, e)
		assert(len(ecs.physics_2d_overlap_circle(&w, {60,20}, 50)) == 0)
	}
}

validate_capsules :: proc(r: ^ecs.Component_Registry) {
	w := ecs.init()
	defer ecs.destroy(&w)
	e := body(&w, r)
	capsule := ecs.CapsuleCollider2D{radius=2, height=10, axis=.horizontal, offset={10,0}}
	assert(ecs.add(&w, r, e, capsule))
	hit, ok := ecs.physics_2d_raycast(&w, {0,0}, {20,0})
	assert(ok && near(hit.point[0],5))
	_, corner_hit := ecs.physics_2d_raycast(&w, {5.1,-5}, {0,3.1})
	assert(!corner_hit, "rounded cap does not fill its bounding-box corner")
	capsule.axis = .vertical
	assert(ecs.set(&w, e, capsule))
	hit, ok = ecs.physics_2d_raycast(&w, {0,0}, {20,0})
	assert(ok && near(hit.point[0],8))
	capsule.height = 4
	assert(ecs.set(&w, e, capsule))
	hit, ok = ecs.physics_2d_raycast(&w, {10,-10}, {0,20})
	assert(ok && near(hit.point[1],-2) && hit.component == "CapsuleCollider2D", "height equal to diameter is a circle")
	transform, _ := ecs.get_transform(&w, e)
	transform.scale = {0,0,1}
	ecs.set_transform(&w, e, transform)
	assert(len(ecs.physics_2d_overlap_circle(&w, {10,0}, 50)) == 0, "collapsed scale creates no invalid native shape")
}

validate_events_and_grounding :: proc(r: ^ecs.Component_Registry) {
	w := ecs.init()
	defer ecs.destroy(&w)
	sensor, visitor := body(&w,r), body(&w,r)
	add(&w,r,sensor,"CapsuleCollider2D",`{"radius":2,"height":10,"offset":[10,0],"is_sensor":true}`)
	add(&w,r,visitor,"CircleCollider2D",`{"radius":1,"offset":[10,0]}`)
	add(&w,r,visitor,"RigidBody2D",`{"gravity_scale":0}`)
	ecs.physics_2d_update(&w,1.0/60)
	began := false
	for event in ecs.physics_2d_events(&w) {
		if event.kind==.Begin && event.is_sensor && event.a.entity==sensor && event.b.entity==visitor {
			assert(event.a.component=="CapsuleCollider2D")
			began = true
		}
	}
	assert(began)
	filter := ecs.Default_Physics_Query_Filter
	filter.include_sensors = false
	filter.ignore = visitor
	assert(len(ecs.physics_2d_overlap_box(&w,{10,0},{5,8},filter))==0)
	assert(ecs.set_runtime_field(&w,r,sensor,"CapsuleCollider2D","offset",parse(`[30,0]`)))
	ecs.physics_2d_update(&w,1.0/60)
	ended := false
	for event in ecs.physics_2d_events(&w) {if event.kind==.End && event.is_sensor {ended=true}}
	assert(ended,"moving a sensor shape publishes its old pair end")
	ecs.destroy_entity(&w,sensor)
	ecs.destroy_entity(&w,visitor)
	floor, player := body(&w,r), body(&w,r)
	add(&w,r,floor,"Transform",`{"position":[0,100,0]}`)
	add(&w,r,floor,"BoxCollider2D",`{"size":[100,10],"offset":[0,5]}`)
	add(&w,r,player,"CapsuleCollider2D",`{"radius":5,"height":20,"offset":[0,-10]}`)
	add(&w,r,player,"RigidBody2D",`{}`)
	for _ in 0..<180 {ecs.physics_2d_update(&w,1.0/60)}
	player_body, _ := ecs.get_rigid_body_2d(&w,player)
	pose, _ := ecs.get_transform(&w,player)
	assert(player_body.grounded && math.abs(pose.position[1]-100)<1,"capsule rests at its feet-based entity origin")
}

validate_scene_reload :: proc(r: ^ecs.Component_Registry) {
	w, loaded := scene.load("tools/collider_2d_validation/fixtures/main.scene.json",r)
	assert(loaded,scene.last_load_error())
	defer ecs.destroy(&w)
	e, found := ecs.find_entity_by_id(&w,"capsule")
	assert(found)
	_, hit := ecs.physics_2d_raycast(&w,{0,0},{40,0})
	assert(hit)
	copy, ok := scene.load("tools/collider_2d_validation/fixtures/main.scene.json",r)
	assert(ok)
	other, _ := ecs.find_entity_by_id(&copy,"capsule")
	assert(ecs.set_runtime_field(&copy,r,other,"CapsuleCollider2D","offset",parse(`[0,20]`)))
	assert(ecs.apply_value_snapshot(&w,&copy))
	ecs.destroy(&copy)
	_, hit = ecs.physics_2d_raycast(&w,{0,0},{40,0})
	assert(!hit,"in-place reload removes old capsule geometry")
	_, hit = ecs.physics_2d_raycast(&w,{0,20},{40,0})
	assert(hit && ecs.is_alive(&w,e))
	report := validation.validate_scene("tools/collider_2d_validation/fixtures/invalid.scene.json")
	defer validation.destroy_report(&report)
	assert(!validation.is_valid(&report) && len(report.diagnostics)==3)
}

validate_gizmos :: proc(r: ^ecs.Component_Registry) {
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(320,200,"Collider gizmo validation")
	defer rl.CloseWindow()
	w := ecs.init()
	defer ecs.destroy(&w)
	camera := body(&w,r)
	add(&w,r,camera,"Camera2D",`{"active":true}`)
	box, circle, capsule := body(&w,r), body(&w,r), body(&w,r)
	add(&w,r,box,"Transform",`{"position":[40,100,0]}`)
	add(&w,r,box,"BoxCollider2D",`{"size":[20,20],"offset":[20,0]}`)
	add(&w,r,circle,"Transform",`{"position":[120,100,0]}`)
	add(&w,r,circle,"CircleCollider2D",`{"radius":10,"offset":[20,0]}`)
	add(&w,r,capsule,"Transform",`{"position":[200,100,0],"scale":[-1,1,1]}`)
	add(&w,r,capsule,"CapsuleCollider2D",`{"radius":10,"height":40,"offset":[-40,0]}`)
	target := rl.LoadRenderTexture(320,200)
	defer rl.UnloadRenderTexture(target)
	rl.BeginTextureMode(target)
	rl.ClearBackground(rl.BLACK)
	gizmos.draw_physics_2d(&w)
	rl.EndTextureMode()
	picture := rl.LoadImageFromTexture(target.texture)
	defer rl.UnloadImage(picture)
	rl.ImageFlipVertical(&picture)
	assert(rl.GetImageColor(picture,50,100)==rl.LIME,"box offset gizmo")
	assert(rl.GetImageColor(picture,40,100)==rl.BLACK,"box entity origin is not its collision center")
	// Check a small neighborhood to allow the backend's circle line rasterization.
	assert(has_lime(picture,150,100),"circle offset gizmo")
	assert(has_lime(picture,250,100) && has_lime(picture,240,80),"capsule sides and round cap")
	assert(rl.GetImageColor(picture,240,100)==rl.BLACK,"capsule outline has no internal cap edges")
}
has_lime :: proc(picture: rl.Image,x,y:i32)->bool {
	for dx:i32=-1;dx<=1;dx+=1 {for dy:i32=-1;dy<=1;dy+=1 {if rl.GetImageColor(picture,x+dx,y+dy)==rl.LIME {return true}}}
	return false
}
main :: proc() {
	r:=ecs.init_registry()
	defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	validate_data(&r)
	validate_offsets(&r)
	validate_capsules(&r)
	validate_events_and_grounding(&r)
	validate_scene_reload(&r)
	for arg in os.args[1:] {if arg=="--runtime" {validate_gizmos(&r)}}
	fmt.println("2D collider offsets, capsules, compound shapes, queries, events, and reload passed")
}
