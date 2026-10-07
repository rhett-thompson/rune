package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "rune:ecs"
import "rune:navigation"
import "rune:scene"
import "rune:terrain"

component_count :: proc(mesh:^navigation.Mesh_3D) -> int {
	seen:=make([]bool,len(mesh.triangles));defer delete(seen)
	stack:=make([dynamic]i32);defer delete(stack)
	count:=0
	for _,i in mesh.triangles {
		if seen[i] {continue}
		count+=1;seen[i]=true;append(&stack,i32(i))
		for len(stack)>0 {
			index:=pop(&stack)
			for neighbor in mesh.triangles[index].neighbors {
				if neighbor>=0 && !seen[neighbor] {seen[neighbor]=true;append(&stack,neighbor)}
			}
		}
	}
	return count
}

compare_simplification :: proc(g:navigation.Bake_Geometry_3D,settings:=navigation.Default_Bake_Settings_3D) -> (int,int) {
	raw_settings:=settings;raw_settings.simplify=false
	raw,raw_stats,error:=navigation.bake_mesh_3d(g,raw_settings);check(error=="",error)
	defer navigation.destroy_mesh_3d(&raw)
	simple_settings:=settings;simple_settings.simplify=true
	simple,simple_stats,simple_error:=navigation.bake_mesh_3d(g,simple_settings);check(simple_error=="",simple_error)
	defer navigation.destroy_mesh_3d(&simple)
	check(raw_stats.output_triangles==raw_stats.walkable_cells*4,"opting out retains four triangles per cell")
	check(simple_stats.walkable_cells==raw_stats.walkable_cells,"simplification does not change clearance filtering")
	check(len(simple.triangles)<=len(raw.triangles),"simplification cannot increase triangle count")
	check(component_count(&simple)==component_count(&raw),"shared-edge connectivity is preserved across all layers")
	for p in raw.vertices {
		_,_,found:=navigation.project_point_3d(&simple,p,0.0003)
		check(found,"all original corner/center samples remain on the simplified surface")
	}
	raw_area,simple_area:f64
	for t in raw.triangles {
		raw_area+=f64(abs(navigation.area_xz(raw.vertices[t.vertices[0]],raw.vertices[t.vertices[1]],raw.vertices[t.vertices[2]])))*0.5
		_,_,found:=navigation.project_point_3d(&simple,t.center,0.0003)
		check(found,"every original triangle remains covered")
	}
	for t in simple.triangles {
		a,b,c:=simple.vertices[t.vertices[0]],simple.vertices[t.vertices[1]],simple.vertices[t.vertices[2]]
		simple_area+=f64(abs(navigation.area_xz(a,b,c)))*0.5
		check(t.normal.y>=math.cos(settings.max_slope*math.PI/180)-1e-5,"simplified triangles respect the slope limit")
		for u in 0..=4 {for v in 0..=4-u {
			p:=a+(b-a)*(f32(u)/4)+(c-a)*(f32(v)/4)
			_,_,found:=navigation.project_point_3d(&raw,p,0.0003)
			check(found,"simplification does not fill holes or invent floor between layers")
		}}
	}
	check(abs(raw_area-simple_area)<max(raw_area,1)*1e-5,"projected surface area is unchanged")
	again,_,again_error:=navigation.bake_mesh_3d(g,simple_settings);check(again_error=="",again_error)
	defer navigation.destroy_mesh_3d(&again)
	check(len(again.vertices)==len(simple.vertices) && len(again.triangles)==len(simple.triangles),"simplification is repeatable")
	for p,i in simple.vertices {check(p==again.vertices[i],"deterministic compact vertices")}
	for t,i in simple.triangles {check(t.vertices==again.triangles[i].vertices,"deterministic simplified triangles")}
	return len(raw.triangles),len(simple.triangles)
}

validate_simplification :: proc() {
	check(navigation.Default_Bake_Settings_3D.simplify,"simplification defaults on")
	config:struct {settings:navigation.Bake_Settings_3D}
	config.settings=navigation.Default_Bake_Settings_3D
	check(json.unmarshal(transmute([]u8)string(`{"settings":{"cell_size":0.25}}`),&config)==nil && config.settings.simplify,"omitted JSON setting retains the default")
	check(json.unmarshal(transmute([]u8)string(`{"settings":{"simplify":false}}`),&config)==nil && !config.settings.simplify,"JSON can disable simplification")
	flat:navigation.Bake_Geometry_3D;defer navigation.destroy_bake_geometry_3d(&flat)
	floor(&flat)
	raw,simple:=compare_simplification(flat)
	check(simple==2 && raw>1000,"a planar rectangular floor becomes two triangles")
	floor(&flat,y=4)
	_,simple=compare_simplification(flat);check(simple==4,"stacked planar floors each simplify independently")
	check(navigation.append_bake_box_3d(&flat,{2,3,4},{0,1.5,0}),"simplification obstacle")
	compare_simplification(flat)
	// Asymmetric adjacent obstacles create holes, corners and unequal shared
	// edges between merged rectangles. Upper floors preserve a separate layer.
	check(navigation.append_bake_box_3d(&flat,{2,6,2},{3,3,-2}),"second obstacle")
	compare_simplification(flat)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);check(ecs.register_builtin_components(&r),"simplification registry")
	w,loaded:=scene.load("examples/navigation_3d/scenes/main.scene.json",&r);check(loaded,"simplification scene");defer ecs.destroy(&w)
	course,collect_error:=ecs.collect_navigation_geometry_3d(&w,"examples/navigation_3d");check(collect_error=="",collect_error);defer navigation.destroy_bake_geometry_3d(&course)
	s:=navigation.Default_Bake_Settings_3D;s.cell_size=0.25
	raw,simple=compare_simplification(course,s)
	check(simple<raw/10,"course retains fine clearance with far fewer navigation triangles")
	fmt.printf("PASS default simplification: course %d -> %d triangles\n",raw,simple)
	// A gently curved heightfield has planar strips plus real slope changes.
	d:=terrain.Data{description=terrain.Description{resolution={17,17},size={8,8}},heights=make([]f32,17*17)}
	defer delete(d.heights)
	for z in 0..<17 {for x in 0..<17 {d.heights[z*17+x]=f32(x)*0.03+0.12*math.sin(f32(z)*0.4)}}
	ground:navigation.Bake_Geometry_3D;defer navigation.destroy_bake_geometry_3d(&ground)
	check(navigation.append_bake_terrain_3d(&ground,d),"simplification terrain")
	compare_simplification(ground)
	warped:navigation.Bake_Geometry_3D;defer navigation.destroy_bake_geometry_3d(&warped)
	for z in 0..<17 {for x in 0..<17 {d.heights[z*17+x]=0.1*math.sin(f32(x)*0.7)*math.cos(f32(z)*0.4)}}
	check(navigation.append_bake_terrain_3d(&warped,d),"nonplanar cells")
	compare_simplification(warped)
	// Fine resolution formerly hit the output limit before a flat surface
	// could be simplified. The limit now applies to the final mesh.
	s.cell_size=0.0625;s.agent_radius=0.0625
	large:navigation.Bake_Geometry_3D;defer navigation.destroy_bake_geometry_3d(&large);floor(&large,{10,10})
	s.simplify=false
	_,_,limit_error:=navigation.bake_mesh_3d(large,s);check(limit_error!="","unsimplified output still obeys the asset limit")
	s.simplify=true
	mesh,stats,error:=navigation.bake_mesh_3d(large,s);check(error=="",error);defer navigation.destroy_mesh_3d(&mesh)
	check(stats.walkable_cells>16384 && len(mesh.triangles)<65536,"simplification happens before enforcing the final triangle limit")
}
