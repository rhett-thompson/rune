package main

import "core:fmt"
import "core:os"
import "rune:navigation"

Coverage_Rectangle :: struct {
	name: string,
	x0,x1,z0,z1: f32,
	cell_size, radius: f32,
	expected: int,
}

coverage_rectangle :: proc(g:^navigation.Bake_Geometry_3D,x0,x1,z0,z1:f32,other_diagonal:=false,
	base_height:f32=0,slope:[2]f32={}) {
	v:=[4][3]f32{{x0,base_height,z0},{x1,base_height+(x1-x0)*slope[0],z0},
		{x1,base_height+(x1-x0)*slope[0]+(z1-z0)*slope[1],z1},{x0,base_height+(z1-z0)*slope[1],z1}}
	t:=[2][3]i32{{0,2,1},{0,3,2}}
	if other_diagonal {t={{0,3,1},{1,3,2}}}
	check(navigation.append_bake_triangles_3d(g,v[:],t[:]),"precision rectangle source")
}

coverage_settings :: proc(cell_size,radius:f32,simplify:bool) -> navigation.Bake_Settings_3D {
	return {cell_size=cell_size,agent_radius=radius,agent_height=2,max_slope=45,simplify=simplify}
}

coverage_bake :: proc(g:navigation.Bake_Geometry_3D,settings:navigation.Bake_Settings_3D,expected:int,name:string) -> navigation.Mesh_3D {
	m,stats,error:=navigation.bake_mesh_3d(g,settings)
	check(error=="",error)
	if stats.walkable_cells!=expected {
		fmt.eprintf("coverage fixture %s, cell %.3f, radius %.3f, simplify %t: expected %d cells, got %d\n",
			name,settings.cell_size,settings.agent_radius,settings.simplify,expected,stats.walkable_cells)
	}
	check(stats.walkable_cells==expected,"fully covered source has no missing or invented cells")
	if !settings.simplify {check(stats.output_triangles==expected*4,"raw precision fixture retains every cell")}
	return m
}

coverage_has_floor :: proc(m:^navigation.Mesh_3D,p:[3]f32) -> bool {
	_,_,found:=navigation.project_point_3d(m,p,0.000001)
	return found
}

coverage_route :: proc(m:^navigation.Mesh_3D,start,goal:[3]f32) -> navigation.Path_Status_3D {
	p:=navigation.find_path_3d(m,start,goal,{radius=m.agent_radius,height=1.8,max_slope=45,max_projection=0.001})
	defer navigation.destroy_path_3d(&p)
	return p.status
}

validate_coverage_box :: proc() {
	g:navigation.Bake_Geometry_3D;defer navigation.destroy_bake_geometry_3d(&g)
	check(navigation.append_bake_box_3d(&g,{1,1,1},scale={40,0.5,40}),"precision report scaled collider")
	for simplify in ([2]bool{false,true}) {
		m:=coverage_bake(g,coverage_settings(0.5,0.35,simplify),6084,"scaled report box")
		check(coverage_route(&m,{-19,0.25,-19},{19,0.25,19})==.Complete,"report box remains connected corner to corner")
		if simplify {check(len(m.triangles)==2,"hole-free report floor simplifies to two triangles")}
		navigation.destroy_mesh_3d(&m)
	}
	settings:=coverage_settings(0.5,0.35,true)
	a:=coverage_bake(g,settings,6084,"deterministic report box");defer navigation.destroy_mesh_3d(&a)
	b:=coverage_bake(g,settings,6084,"repeated report box");defer navigation.destroy_mesh_3d(&b)
	check(navigation.write_mesh_3d("build/coverage-precision-a.navmesh.json",&a)=="","write first precision bake")
	check(navigation.write_mesh_3d("build/coverage-precision-b.navmesh.json",&b)=="","write repeated precision bake")
	first,first_error:=os.read_entire_file("build/coverage-precision-a.navmesh.json",context.allocator);defer delete(first)
	second,second_error:=os.read_entire_file("build/coverage-precision-b.navmesh.json",context.allocator);defer delete(second)
	check(first_error==nil && second_error==nil && string(first)==string(second),"precision bake serialization is byte deterministic")
	loaded,error:=navigation.load_mesh_3d("build/coverage-precision-a.navmesh.json");defer navigation.destroy_mesh_3d(&loaded)
	check(error=="" && coverage_route(&loaded,{-19,0.25,-19},{19,0.25,19})==.Complete,"serialized precision bake preserves its route")
}

validate_coverage_rectangles :: proc() {
	// Absolute cell counts catch rasterizer holes that raw/simplified comparisons
	// cannot: both mesh forms previously shared the same missing cells.
	fixtures:=[?]Coverage_Rectangle{
		{"flat report rectangle",-20,20,-20,20,0.5,0.35,6084},
		{"quarter-cell shift",-19.875,20.125,-20.375,19.625,0.5,0,6241},
		{"quarter-cell shift eroded",-19.875,20.125,-20.375,19.625,0.5,0.35,5929},
		{"large aligned offset",1004,1044,-4116,-4076,0.5,0.35,6084},
		{"decimal .3",-19.87,20.13,-20.27,19.73,0.3,0,17556},
		{"decimal .3 eroded",-19.87,20.13,-20.27,19.73,0.3,0.35,16512},
		{"decimal .2",-19.87,20.13,-20.27,19.73,0.2,0,39601},
		{"decimal .2 eroded",-19.87,20.13,-20.27,19.73,0.2,0.35,38025},
		{"decimal .7",-19.87,20.13,-20.27,19.73,0.7,0,3136},
		{"decimal .7 eroded",-19.87,20.13,-20.27,19.73,0.7,0.35,2916},
		{"nonuniform decimal rectangle",-27.43,27.77,-10.17,9.63,0.3,0,11895},
		{"nonuniform decimal rectangle eroded",-27.43,27.77,-10.17,9.63,0.3,0.35,10919},
	}
	for fixture in fixtures {for other_diagonal in ([2]bool{false,true}) {
		g:navigation.Bake_Geometry_3D
		coverage_rectangle(&g,fixture.x0,fixture.x1,fixture.z0,fixture.z1,other_diagonal)
		for simplify in ([2]bool{false,true}) {
			// Fine raw grids exceed the existing 65536-triangle asset limit.
			if !simplify && fixture.expected*4>65536 {continue}
			m:=coverage_bake(g,coverage_settings(fixture.cell_size,fixture.radius,simplify),fixture.expected,fixture.name)
			check(len(m.triangles)==2 || !simplify,"fully covered planar rectangle simplifies without pinholes")
			start:=[3]f32{fixture.x0+2,0,fixture.z0+2}
			goal:=[3]f32{fixture.x1-2,0,fixture.z1-2}
			check(coverage_route(&m,start,goal)==.Complete,"precision rectangle preserves its interior route")
			navigation.destroy_mesh_3d(&m)
		}
		navigation.destroy_bake_geometry_3d(&g)
	}}
}

validate_coverage_gaps :: proc() {
	// These gaps are representable in f32 and exceed the unchanged area tolerance.
	// Projection/precision must not turn a missing sliver into supporting floor.
	for gap_width in ([3]f32{0.01,0.0001,0.000001}) {
		g:navigation.Bake_Geometry_3D
		coverage_rectangle(&g,-20,0.25-gap_width*0.5,-20,20)
		coverage_rectangle(&g,0.25+gap_width*0.5,20,-20,20,true)
		for simplify in ([2]bool{false,true}) {
			m,_,error:=navigation.bake_mesh_3d(g,coverage_settings(0.5,0,simplify));check(error=="",error)
			check(!coverage_has_floor(&m,{0.25,0,0}),"true slit remains unsupported")
			check(coverage_route(&m,{-10,0,0},{10,0,0})==.Unreachable,"true slit still disconnects the floor")
			navigation.destroy_mesh_3d(&m)
		}
		navigation.destroy_bake_geometry_3d(&g)
	}
	for center in ([2][2]f32{{0.25,0.25},{0.17,0.11}}) {for duplicate in ([2]bool{false,true}) {
		g:navigation.Bake_Geometry_3D
		x0,x1,z0,z1:=center[0]-0.0005,center[0]+0.0005,center[1]-0.0005,center[1]+0.0005
		coverage_rectangle(&g,-20,x0,-20,20)
		coverage_rectangle(&g,x1,20,-20,20,true)
		coverage_rectangle(&g,x0,x1,-20,z0)
		coverage_rectangle(&g,x0,x1,z1,20)
		if duplicate {coverage_rectangle(&g,-20,x0,-20,20);coverage_rectangle(&g,x1,20,-20,20,true)}
		for simplify in ([2]bool{false,true}) {
			m,_,error:=navigation.bake_mesh_3d(g,coverage_settings(0.5,0,simplify));check(error=="",error)
			check(!coverage_has_floor(&m,{center[0],0,center[1]}),"true subcell hole remains unsupported even with duplicate patches")
			check(coverage_has_floor(&m,{-1,0,-1}),"true hole does not remove unrelated support")
			navigation.destroy_mesh_3d(&m)
		}
		navigation.destroy_bake_geometry_3d(&g)
	}}
	g:navigation.Bake_Geometry_3D;defer navigation.destroy_bake_geometry_3d(&g)
	v:=[3][3]f32{{0,0,0},{0,0,3},{3,0,0}};t:=[1][3]i32{{0,1,2}}
	check(navigation.append_bake_triangles_3d(&g,v[:],t[:]),"partial precision triangle source")
	for simplify in ([2]bool{false,true}) {
		m:=coverage_bake(g,coverage_settings(0.5,0,simplify),15,"partially covered boundary cells")
		check(coverage_has_floor(&m,{0.25,0,0.25}) && !coverage_has_floor(&m,{2.75,0,0.25}),"partial boundary cells remain conservatively excluded")
		navigation.destroy_mesh_3d(&m)
	}
}

validate_coverage_slopes :: proc() {
	fixtures:=[2]Coverage_Rectangle{
		{"translated sloped rectangle",1004,1044,-4116,-4076,0.5,0.35,6084},
		{"decimal sloped rectangle",-19.87,20.13,-20.27,19.73,0.3,0.35,16512},
	}
	for fixture in fixtures {for other_diagonal in ([2]bool{false,true}) {
		g:navigation.Bake_Geometry_3D
		coverage_rectangle(&g,fixture.x0,fixture.x1,fixture.z0,fixture.z1,other_diagonal,3,{0.125,0.0625})
		for simplify in ([2]bool{false,true}) {
			if !simplify && fixture.expected*4>65536 {continue}
			m:=coverage_bake(g,coverage_settings(fixture.cell_size,fixture.radius,simplify),fixture.expected,fixture.name)
			for p in m.vertices {
				height:=3+(p.x-fixture.x0)*0.125+(p.z-fixture.z0)*0.0625
				check(abs(p.y-height)<0.00003,"precision clipping preserves translated slope heights")
			}
			start:=[3]f32{fixture.x0+2,3.375,fixture.z0+2}
			goal:=[3]f32{fixture.x1-2,3+(fixture.x1-fixture.x0-2)*0.125+(fixture.z1-fixture.z0-2)*0.0625,fixture.z1-2}
			check(coverage_route(&m,start,goal)==.Complete,"translated slope remains connected")
			navigation.destroy_mesh_3d(&m)
		}
		navigation.destroy_bake_geometry_3d(&g)
	}}
}

validate_coverage_elevated_support :: proc() {
	// Side faces end on this sloped floor. Rounding an internal support height
	// to f32 at y=4096 used to put the face above support and remove valid cells.
	g:navigation.Bake_Geometry_3D;defer navigation.destroy_bake_geometry_3d(&g)
	position:=[3]f32{0,4096,0};rotation:=[3]f32{0,0,15}
	check(navigation.append_bake_box_3d(&g,{40,0.5,40},position,rotation),"elevated sloped support source")
	start:=navigation.bake_transform_point_3d({-18,0.25,-18},position,rotation,{1,1,1})
	goal:=navigation.bake_transform_point_3d({18,0.25,18},position,rotation,{1,1,1})
	for simplify in ([2]bool{false,true}) {
		m:=coverage_bake(g,coverage_settings(0.5,0.35,simplify),5772,"elevated sloped support")
		check(coverage_route(&m,start,goal)==.Complete,"elevated side faces preserve their supporting floor")
		navigation.destroy_mesh_3d(&m)
	}
}

validate_coverage_precision :: proc() {
	validate_coverage_box()
	validate_coverage_rectangles()
	validate_coverage_gaps()
	validate_coverage_slopes()
	validate_coverage_elevated_support()
	fmt.println("PASS bake precision: absolute coverage, decimal grids, real holes/slits, slopes and serialization")
}
