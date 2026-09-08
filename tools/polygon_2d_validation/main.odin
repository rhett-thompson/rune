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
	e := body(&w,r)
	points := [3][2]f32{{0,0},{20,-10},{20,0}}
	assert(ecs.add(&w,r,e,ecs.PolygonCollider2D{vertices=points[:]}))
	points[1] = {20,-20}
	stored, _ := ecs.get(&w,e,ecs.PolygonCollider2D)
	assert(stored.vertices[1]==[2]f32{20,-10}, "add owns a copy")
	assert(ecs.set(&w,e,ecs.PolygonCollider2D{vertices=points[:]}))
	points[1] = {20,-30}
	stored, _ = ecs.get(&w,e,ecs.PolygonCollider2D)
	assert(stored.vertices[1]==[2]f32{20,-20}, "set owns a copy")
	stored.offset = {5,0}
	assert(ecs.set(&w,e,stored), "set accepts a borrowed slice without use-after-free")
	for invalid in ([]string{
		`{}`, `{"vertices":[]}`, `{"vertices":[[0,0],[10,0]]}`,
		`{"vertices":[[0,0],[10,0],[20,0]]}`,
		`{"vertices":[[0,0],[10,0],[10,0],[0,10]]}`,
		`{"vertices":[[0,0],[10,0],[5,2],[10,10],[0,10]]}`,
		`{"vertices":[[0,0],[10,10],[0,10],[10,0]]}`,
		`{"vertices":[[0,0],[0.001,0],[0,0.001]]}`,
		`{"vertices":[[0,0],[10,0],[0,10]],"unknown":true}`,
		`{"vertices":[[0,0],[10,0],[0,10]],"is_sensor":1}`,
		`{"vertices":[[0,0],[10,0],[0,10]],"offset":[0]}`,
		`{"vertices":[[0,0],[10,"x"],[0,10]]}`,
		`{"vertices":[[0,0],[10,0],[20,0],[30,0],[40,0],[50,0],[60,0],[70,0],[80,0]]}`,
	}) {assert(!ecs.add_component(&w,r,e,"PolygonCollider2D",parse(invalid)),invalid)}
	points[0][0] = math.nan_f32()
	assert(!ecs.set(&w,e,ecs.PolygonCollider2D{vertices=points[:]}))
	// Either winding is valid; runtime serialization keeps the authored order.
	add(&w,r,e,"PolygonCollider2D",`{"vertices":[[20,0],[20,-10],[0,0]]}`)
	add(&w,r,e,"SegmentCollider2D",`{"start":[0,20],"end":[20,20]}`)
	for name in ([]string{"PolygonCollider2D","SegmentCollider2D"}) {
		data, ok := ecs.runtime_component_json(&w,e,name)
		assert(ok && ecs.add_component(&w,r,e,name,data),"JSON roundtrip")
	}
	for invalid in ([]string{`{}`,`{"start":[0,0]}`,`{"start":[0,0],"end":[0,0]}`,`{"start":[0,0],"end":[0.001,0]}`,`{"start":[0,0],"end":[10,0],"is_sensor":1}`}) {
		assert(!ecs.add_component(&w,r,e,"SegmentCollider2D",parse(invalid)),invalid)
	}
	assert(!ecs.set(&w,e,ecs.SegmentCollider2D{end={math.inf_f32(1),0}}))
	assert(!ecs.set(&w,e,ecs.SegmentCollider2D{end={10,0},offset={math.nan_f32(),0}}))
}

validate_queries :: proc(r: ^ecs.Component_Registry) {
	for moving in ([]bool{false,true}) {
		w := ecs.init()
		defer ecs.destroy(&w)
		e := body(&w,r)
		if moving {add(&w,r,e,"RigidBody2D",`{"gravity_scale":0}`)}
		add(&w,r,e,"PolygonCollider2D",`{"vertices":[[0,0],[20,-10],[20,0]],"offset":[10,0]}`)
		assert(ecs.add(&w,r,e,ecs.SegmentCollider2D{start={0,20},end={20,20},offset={10,0}}))
		hit, ok := ecs.physics_2d_raycast(&w,{20,-30},{0,40})
		assert(ok && hit.component=="PolygonCollider2D" && near(hit.point[1],-5))
		hit, ok = ecs.physics_2d_raycast(&w,{20,10},{0,20})
		assert(ok && hit.component=="SegmentCollider2D" && near(hit.point[1],20))
		hit, ok = ecs.physics_2d_raycast(&w,{20,30},{0,-20})
		assert(ok && hit.component=="SegmentCollider2D", "two-sided edge")
		assert(len(w.box2d_bodies)==1 && len(w.physics_2d.shapes)==2)
		assert(len(ecs.physics_2d_overlap_circle(&w,{20,10},30))==1)
		assert(len(ecs.physics_2d_overlap_box(&w,{11,-8},{1,1}))==0,"triangle is not its AABB")
		pose,_ := ecs.get_transform(&w,e)
		pose.position,pose.scale = {100,100,0},{-2,3,1}
		ecs.set_transform(&w,e,pose)
		hit,ok = ecs.physics_2d_raycast(&w,{60,50},{0,60})
		assert(ok && hit.component=="PolygonCollider2D" && near(hit.point[1],85))
		hit,ok = ecs.physics_2d_raycast(&w,{60,120},{0,80})
		assert(ok && hit.component=="SegmentCollider2D" && near(hit.point[1],160))
		assert(ecs.set_runtime_field(&w,r,e,"PolygonCollider2D","vertices.1.1",parse(`-20`)))
		hit,ok = ecs.physics_2d_raycast(&w,{60,20},{0,100})
		assert(ok && near(hit.point[1],70),"vertex edit rebuilds")
		assert(!ecs.set_runtime_field(&w,r,e,"PolygonCollider2D","vertices.1",parse(`[0,0]`)))
		assert(ecs.set_runtime_field(&w,r,e,"SegmentCollider2D","offset",parse(`[10,10]`)))
		hit,ok = ecs.physics_2d_raycast(&w,{60,120},{0,100})
		assert(ok && near(hit.point[1],190),"segment edit rebuilds")
		ecs.set_enabled(&w,e,false)
		assert(len(ecs.physics_2d_overlap_circle(&w,{60,100},100))==0)
		ecs.set_enabled(&w,e,true)
		assert(len(ecs.physics_2d_overlap_circle(&w,{60,100},100))==1)
		pose.scale = {0,0,1}
		ecs.set_transform(&w,e,pose)
		assert(len(ecs.physics_2d_overlap_circle(&w,{100,100},100))==0,"collapsed scale is safe")
		pose.scale = {1,1,1}
		ecs.set_transform(&w,e,pose)
		assert(ecs.remove_component(&w,e,"PolygonCollider2D"))
		assert(len(ecs.physics_2d_overlap_circle(&w,{100,100},100))==1 && len(w.physics_2d.shapes)==1)
		ecs.destroy_entity(&w,e)
		assert(len(ecs.physics_2d_overlap_circle(&w,{100,100},100))==0)
	}
}

validate_events :: proc(r: ^ecs.Component_Registry) {
	for name in ([]string{"PolygonCollider2D","SegmentCollider2D"}) {
		w := ecs.init()
		defer ecs.destroy(&w)
		sensor, visitor := body(&w,r), body(&w,r)
		data := `{"vertices":[[-10,-10],[10,-10],[10,10],[-10,10]],"is_sensor":true}` if name=="PolygonCollider2D" else `{"start":[-10,0],"end":[10,0],"is_sensor":true}`
		add(&w,r,sensor,name,data)
		add(&w,r,visitor,"CircleCollider2D",`{"radius":2}`)
		add(&w,r,visitor,"RigidBody2D",`{"gravity_scale":0}`)
		ecs.physics_2d_update(&w,1.0/60)
		began := false
		for event in ecs.physics_2d_events(&w) {
			if event.kind==.Begin && event.is_sensor && event.a.entity==sensor && event.b.entity==visitor {began = true; assert(event.a.component==name)}
		}
		assert(began,name)
		filter := ecs.Default_Physics_Query_Filter
		filter.ignore,filter.include_sensors = visitor,false
		assert(len(ecs.physics_2d_overlap_circle(&w,{0,0},5,filter))==0)
		assert(ecs.set_runtime_field(&w,r,sensor,name,"offset",parse(`[50,0]`)))
		ecs.physics_2d_update(&w,1.0/60)
		ended := false
		for event in ecs.physics_2d_events(&w) {if event.kind==.End && event.is_sensor {ended=true}}
		assert(ended)
	}
	for name in ([]string{"PolygonCollider2D","SegmentCollider2D"}) {
		w := ecs.init()
		defer ecs.destroy(&w)
		floor, player := body(&w,r),body(&w,r)
		data := `{"vertices":[[-100,100],[100,80],[100,120],[-100,120]]}` if name=="PolygonCollider2D" else `{"start":[-100,100],"end":[100,100]}`
		add(&w,r,floor,name,data)
		add(&w,r,player,"CapsuleCollider2D",`{"radius":5,"height":20}`)
		add(&w,r,player,"RigidBody2D",`{}`)
		for _ in 0..<180 {ecs.physics_2d_update(&w,1.0/60)}
		pose,_ := ecs.get_transform(&w,player)
		rb,_ := ecs.get_rigid_body_2d(&w,player)
		assert(rb.grounded && pose.position[1]>70 && pose.position[1]<100,"solid grounding")
	}
}

validate_reload :: proc(r: ^ecs.Component_Registry) {
	w,ok := scene.load("tools/polygon_2d_validation/fixtures/main.scene.json",r)
	assert(ok,scene.last_load_error())
	defer ecs.destroy(&w)
	e,_ := ecs.find_entity_by_id(&w,"ramp")
	copy,loaded := scene.load("tools/polygon_2d_validation/fixtures/main.scene.json",r)
	assert(loaded)
	other,_ := ecs.find_entity_by_id(&copy,"ramp")
	assert(ecs.set_runtime_field(&copy,r,other,"PolygonCollider2D","vertices.1.1",parse(`-20`)))
	assert(ecs.set_runtime_field(&copy,r,other,"SegmentCollider2D","end.1",parse(`40`)))
	assert(ecs.apply_value_snapshot(&w,&copy))
	ecs.destroy(&copy)
	hit,found := ecs.physics_2d_raycast(&w,{10,-30},{0,40})
	assert(found && hit.entity==e && near(hit.point[1],-10),"polygon clone survives donor destruction")
	hit,found = ecs.physics_2d_raycast(&w,{10,10},{0,40})
	assert(found && hit.component=="SegmentCollider2D" && near(hit.point[1],30))
	report := validation.validate_scene("tools/polygon_2d_validation/fixtures/invalid.scene.json")
	defer validation.destroy_report(&report)
	assert(!validation.is_valid(&report) && len(report.diagnostics)==2)
}

validate_gizmos :: proc(r: ^ecs.Component_Registry) {
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(200,200,"Polygon and segment gizmos")
	defer rl.CloseWindow()
	w := ecs.init()
	defer ecs.destroy(&w)
	e := body(&w,r)
	add(&w,r,e,"Transform",`{"position":[100,100,0],"scale":[-2,3,1]}`)
	add(&w,r,e,"PolygonCollider2D",`{"vertices":[[0,0],[20,-10],[20,0]],"offset":[10,0]}`)
	add(&w,r,e,"SegmentCollider2D",`{"start":[0,20],"end":[20,20],"offset":[10,0]}`)
	target := rl.LoadRenderTexture(200,200)
	defer rl.UnloadRenderTexture(target)
	rl.BeginTextureMode(target)
	rl.ClearBackground(rl.BLACK)
	gizmos.draw_physics_2d(&w)
	rl.EndTextureMode()
	picture := rl.LoadImageFromTexture(target.texture)
	defer rl.UnloadImage(picture)
	rl.ImageFlipVertical(&picture)
	assert(rl.GetImageColor(picture,60,85)==rl.LIME,"scaled polygon slope")
	assert(rl.GetImageColor(picture,60,160)==rl.LIME,"scaled segment")
	assert(rl.GetImageColor(picture,60,95)==rl.BLACK,"outline only")
	// Collapse X only: a triangle and horizontal segment become degenerate.
	add(&w,r,e,"Transform",`{"position":[100,100,0],"scale":[0,3,1]}`)
	rl.BeginTextureMode(target)
	rl.ClearBackground(rl.BLACK)
	gizmos.draw_physics_2d(&w)
	rl.EndTextureMode()
	collapsed := rl.LoadImageFromTexture(target.texture)
	defer rl.UnloadImage(collapsed)
	rl.ImageFlipVertical(&collapsed)
	assert(rl.GetImageColor(collapsed,100,85)==rl.BLACK,"collapsed polygon has no physical outline")
	assert(rl.GetImageColor(collapsed,100,160)==rl.BLACK,"collapsed segment has no physical outline")
}

main :: proc() {
	r := ecs.init_registry()
	defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	validate_data(&r)
	validate_queries(&r)
	validate_events(&r)
	validate_reload(&r)
	for arg in os.args[1:] {if arg=="--runtime" {validate_gizmos(&r)}}
	fmt.println("Polygon/segment validation, ownership, queries, sensors, grounding, and reload passed")
}
