package main

import "core:fmt"

import "core:math"
import "core:os"
import "rune:ecs"
import "rune:navigation"
import "rune:scene"
import "rune:terrain"

check :: proc(ok:bool,message:string) {if !ok {fmt.eprintln("FAIL navigation bake:",message);os.exit(1)}}
floor :: proc(g:^navigation.Bake_Geometry_3D,size:[2]f32={12,12},y:f32=0) {
	x,z:=size[0]*0.5,size[1]*0.5
	v:=[4][3]f32{{-x,y,-z},{x,y,-z},{x,y,z},{-x,y,z}}
	t:=[2][3]i32{{0,2,1},{0,3,2}}
	check(navigation.append_bake_triangles_3d(g,v[:],t[:]),"append floor")
}
bake :: proc(g:navigation.Bake_Geometry_3D,s:=navigation.Default_Bake_Settings_3D) -> navigation.Mesh_3D {
	m,stats,error:=navigation.bake_mesh_3d(g,s)
	check(error=="",error);check(stats.walkable_cells>0 && stats.output_triangles==len(m.triangles),"bake statistics")
	return m
}
route :: proc(m:^navigation.Mesh_3D,a,b:[3]f32) -> navigation.Path_Status_3D {
	p:=navigation.find_path_3d(m,a,b);defer navigation.destroy_path_3d(&p);return p.status
}
has_floor :: proc(m:^navigation.Mesh_3D,p:[3]f32) -> bool {_,_,ok:=navigation.project_point_3d(m,p,0.01);return ok}
main :: proc() {
	validate_flat_and_obstacles()
	validate_layers()
	validate_terrain()
	validate_scene()
	validate_limits()
	fmt.println("Navigation bake validation passed: radius erosion, obstacle clearance, thin walls, ceilings, stacked floors, terrain topology/transforms/slopes, scene collection, determinism, serialization and invalid inputs")
}
validate_flat_and_obstacles :: proc() {
	g:navigation.Bake_Geometry_3D;defer navigation.destroy_bake_geometry_3d(&g)
	floor(&g)
	check(navigation.append_bake_box_3d(&g,{2,3,4},{0,1.5,0}),"obstacle box")
	m:=bake(g);defer navigation.destroy_mesh_3d(&m)
	check(route(&m,{-4,0,0},{4,0,0})==.Complete,"route around obstacle")
	check(!has_floor(&m,{0,0,0}),"solid obstacle cannot contain a floor")
	for p in m.vertices {
		check(abs(p.x)<=5.5+0.001 && abs(p.z)<=5.5+0.001,"radius erodes exterior edges")
		if p.y<1 {
			dx,dz:=max(abs(p.x)-1,0),max(abs(p.z)-2,0)
			check(math.sqrt(dx*dx+dz*dz)>=0.4-0.001,"radius erodes obstacle boundary")
		}
	}
	// Duplicate input surfaces must not create duplicated output or fill holes.
	floor(&g)
	duplicate:=bake(g);defer navigation.destroy_mesh_3d(&duplicate)
	check(len(m.triangles)==len(duplicate.triangles),"overlapping floor union")
	check(navigation.write_mesh_3d("build/bake-test.navmesh.json",&m)=="","write baked asset")
	loaded,error:=navigation.load_mesh_3d("build/bake-test.navmesh.json");defer navigation.destroy_mesh_3d(&loaded)
	check(error=="" && route(&loaded,{-4,0,0},{4,0,0})==.Complete,"serialized mesh path round trip")
	wall_v:=[4][3]f32{{0,0,-6},{0,4,-6},{0,4,6},{0,0,6}}
	wall_t:=[2][3]i32{{0,1,2},{0,2,3}}
	check(navigation.append_bake_triangles_3d(&g,wall_v[:],wall_t[:]),"thin wall")
	walled:=bake(g);defer navigation.destroy_mesh_3d(&walled)
	check(route(&walled,{-4,0,0},{4,0,0})==.Unreachable,"zero-thickness wall blocks route")
	narrow:navigation.Bake_Geometry_3D;defer navigation.destroy_bake_geometry_3d(&narrow)
	floor(&narrow,{1,8})
	_,_,err:=navigation.bake_mesh_3d(narrow,{cell_size=0.25,agent_radius=0.6,agent_height=2,max_slope=45})
	check(err!="","corridor too narrow for radius is removed")
}
validate_layers :: proc() {
	g:navigation.Bake_Geometry_3D;defer navigation.destroy_bake_geometry_3d(&g)
	floor(&g);floor(&g,y=4)
	m:=bake(g);defer navigation.destroy_mesh_3d(&m)
	check(route(&m,{-4,0,0},{4,0,0})==.Complete && route(&m,{-4,4,0},{4,4,0})==.Complete,"separate walkable stacked floors")
	check(route(&m,{0,0,0},{0,4,0})==.Unreachable,"no invented inter-floor link")
	check(navigation.append_bake_box_3d(&g,{6,0.2,6},{0,1.4,0}),"low ceiling")
	low:=bake(g);defer navigation.destroy_mesh_3d(&low)
	check(!has_floor(&low,{0,0,0}) && has_floor(&low,{0,4,0}),"headroom rejects lower floor only")
	check(route(&low,{-4,0,0},{4,0,0})==.Complete,"route around low headroom")
}
validate_terrain :: proc() {
	d:=terrain.Data{description=terrain.Description{resolution={65,65},size={32,32}},heights=make([]f32,65*65)}
	defer delete(d.heights)
	for z in 0..<65 {for x in 0..<65 {d.heights[z*65+x]=f32(x)*0.5*0.125+0.1*math.sin(f32(z)*0.1)}}
	g:navigation.Bake_Geometry_3D;defer navigation.destroy_bake_geometry_3d(&g)
	check(navigation.append_bake_terrain_3d(&g,d),"terrain source")
	check(len(g.triangles)==8192,"terrain source includes every cell across chunk borders")
	m:=bake(g);defer navigation.destroy_mesh_3d(&m)
	for p in m.vertices {height,ok:=terrain.sample_height(d,p.x,p.z);check(ok && abs(p.y-height)<0.002,"baked aligned terrain matches heightmap triangles")}
	a,_:=terrain.sample_height(d,2,16);b,_:=terrain.sample_height(d,30,16)
	check(route(&m,{2,a,16},{30,b,16})==.Complete,"terrain path across chunk boundaries")
	_,_,error:=navigation.bake_mesh_3d(g,{cell_size=0.5,agent_radius=0.4,agent_height=2,max_slope=3})
	check(error!="","steep terrain removed")
	// Positive nonuniform scale, translation and yaw must reach baked geometry.
	transformed:navigation.Bake_Geometry_3D;defer navigation.destroy_bake_geometry_3d(&transformed)
	check(navigation.append_bake_terrain_3d(&transformed,d,{10,3,-5},{0,90,0},{2,1,1}),"transformed terrain")
	tm:=bake(transformed,{cell_size=1,agent_radius=0.4,agent_height=2,max_slope=45});defer navigation.destroy_mesh_3d(&tm)
	start:=navigation.bake_transform_point_3d({2,a,16},{10,3,-5},{0,90,0},{2,1,1})
	goal:=navigation.bake_transform_point_3d({30,b,16},{10,3,-5},{0,90,0},{2,1,1})
	check(route(&tm,start,goal)==.Complete,"transformed terrain route")
	// A collider on the terrain must cut the same bake, rather than being baked separately.
	check(navigation.append_bake_box_3d(&g,{4,8,4},{16,4,16}),"terrain obstacle")
	blocked:=bake(g);defer navigation.destroy_mesh_3d(&blocked)
	h0,_:=terrain.sample_height(d,16,16)
	check(!has_floor(&blocked,{16,h0,16}),"terrain obstacle footprint removed")
	check(route(&blocked,{2,a,16},{30,b,16})==.Complete,"terrain detour around scene geometry")
}
validate_scene :: proc() {
	r:=ecs.init_registry();defer ecs.destroy_registry(&r);check(ecs.register_builtin_components(&r),"registry")
	w,ok:=scene.load("examples/navigation_3d/scenes/main.scene.json",&r);check(ok,"load demo scene");defer ecs.destroy(&w)
	m,_,error:=ecs.bake_navigation_world_3d(&w,"examples/navigation_3d",{cell_size=0.25,agent_radius=0.4,agent_height=2,max_slope=45})
	check(error=="",error);defer navigation.destroy_mesh_3d(&m)
	check(route(&m,{-7,0,3},{7,2,3})==.Complete,"scene collider ramp joins both floors")
	m2,_,error2:=ecs.bake_navigation_world_3d(&w,"examples/navigation_3d",{cell_size=0.25,agent_radius=0.4,agent_height=2,max_slope=45})
	check(error2=="",error2);defer navigation.destroy_mesh_3d(&m2)
	check(len(m.vertices)==len(m2.vertices) && len(m.triangles)==len(m2.triangles),"repeatable bake sizes")
	for p,i in m.vertices {check(p==m2.vertices[i],"deterministic vertices")}
	for t,i in m.triangles {check(t.vertices==m2.triangles[i].vertices,"deterministic topology")}
	fixture:=`{"name":"Bake fixture","entities":[
		{"id":"static","components":{"Transform":{},"BoxCollider":{"size":[12,1,12]}}},
		{"id":"sensor","components":{"Transform":{},"BoxCollider":{"is_sensor":true}}},
		{"id":"disabled","enabled":false,"components":{"Transform":{},"BoxCollider":{}}},
		{"id":"dynamic","components":{"Transform":{},"RigidBody3D":{},"BoxCollider":{}}},
		{"id":"kinematic","components":{"Transform":{},"RigidBody3D":{"type":"kinematic"},"SphereCollider":{}}},
		{"id":"sphere","components":{"Transform":{"scale":[1,2,1]},"SphereCollider":{"radius":0.5}}}
	]}`
	check(os.write_entire_file("build/bake-collection.scene.json",transmute([]u8)fixture)==nil,"write collection fixture")
	filtered,loaded:=scene.load("build/bake-collection.scene.json",&r);check(loaded,scene.last_load_error());defer ecs.destroy(&filtered)
	g,collection_error:=ecs.collect_navigation_geometry_3d(&filtered,".");defer navigation.destroy_bake_geometry_3d(&g)
	check(collection_error=="" && len(g.triangles)==24,"collector skips sensors, disabled entities and moving bodies")
	check(len(g.obstacle_triangles)==12 && len(g.solids)==2,"sphere is a closed nonwalkable conservative blocker")
	// Real R16 loading and accumulated terrain parent transforms.
	check(os.write_entire_file("build/bake-height.r16",[]u8{0,0,0,0,0,0,0,0})==nil,"write r16")
	check(os.write_entire_file("build/bake-height.terrain.json",string(`{"heightmap":"build/bake-height.r16","resolution":[2,2],"size":[8,8]}`))==nil,"write terrain descriptor")
	check(os.write_entire_file("build/bake-terrain.scene.json",string(`{"name":"Bake fixture","entities":[{"id":"parent","components":{"Transform":{"position":[10,3,20],"scale":[2,1,1]}},"children":[{"id":"ground","components":{"Transform":{"position":[1,2,3]},"Terrain":{"asset":"build/bake-height.terrain.json"}}}]}]}`))==nil,"write terrain scene")
	tw,terrain_loaded:=scene.load("build/bake-terrain.scene.json",&r);check(terrain_loaded,scene.last_load_error());defer ecs.destroy(&tw)
	tg,terrain_error:=ecs.collect_navigation_geometry_3d(&tw,".");defer navigation.destroy_bake_geometry_3d(&tg)
	check(terrain_error=="" && len(tg.vertices)==4 && tg.vertices[0]==([3]f32{11,5,23}) && tg.vertices[3]==([3]f32{27,5,31}),"R16 terrain collector includes parent transform")
	// A broken terrain source fails the bake instead of silently omitting it.
	ground,_:=ecs.find_entity_by_id(&tw,"ground")
	settings,_:=ecs.get_terrain(&tw,ground);settings.asset="missing.terrain.json";check(ecs.set_terrain(&tw,ground,settings),"change terrain path")
	failed,_,failed_error:=ecs.bake_navigation_world_3d(&tw,".");defer navigation.destroy_mesh_3d(&failed)
	check(failed_error!="","missing terrain fails bake")
}
validate_limits :: proc() {
	small:navigation.Bake_Geometry_3D;defer navigation.destroy_bake_geometry_3d(&small)
	floor(&small,{0.1,0.1})
	small_mesh:=bake(small,{cell_size=0.01,agent_radius=0.01,agent_height=0.02,max_slope=45});defer navigation.destroy_mesh_3d(&small_mesh)
	check(len(small_mesh.triangles)>0,"minimum-size cells retain valid support")
	g:navigation.Bake_Geometry_3D;defer navigation.destroy_bake_geometry_3d(&g);floor(&g)
	_,_,error:=navigation.bake_mesh_3d(g,{cell_size=0,agent_radius=0.4,agent_height=2,max_slope=45});check(error!="","invalid settings")
	_,_,error=navigation.bake_mesh_3d(g,{cell_size=0.01,agent_radius=0,agent_height=2,max_slope=45});check(error!="","oversized grid")
	g.triangles[0][0]=-1
	_,_,error=navigation.bake_mesh_3d(g);check(error!="","invalid index")
	g.triangles[0][0]=0;g.vertices[0].x=transmute(f32)u32(0x7fc00000)
	_,_,error=navigation.bake_mesh_3d(g);check(error!="","nonfinite vertex")
	mesh,load_error:=navigation.load_mesh_3d("build/bake-test.navmesh.json");check(load_error=="",load_error);defer navigation.destroy_mesh_3d(&mesh)
	before,_:=os.read_entire_file("build/bake-test.navmesh.json",context.allocator);defer delete(before)
	mesh.agent_radius=-1
	check(navigation.write_mesh_3d("build/bake-test.navmesh.json",&mesh)!="","invalid output rejected")
	after,_:=os.read_entire_file("build/bake-test.navmesh.json",context.allocator);defer delete(after)
	check(string(before)==string(after),"failed write preserves existing mesh")
}


