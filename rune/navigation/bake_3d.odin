package navigation

import "core:encoding/json"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// CPU-only triangle soup. Winding matters: upward faces are potential floors;
// downward faces and steep/vertical faces still participate in solid clearance.
Bake_Geometry_3D :: struct {
	vertices: [dynamic][3]f32,
	triangles: [dynamic][3]i32,
	obstacle_triangles: map[int]bool,
	solids: [dynamic]Bake_Solid_3D,
}
Bake_Solid_3D :: struct {first,last: int, low,high: [3]f32}
Bake_Settings_3D :: struct {
	cell_size: f32,
	agent_radius, agent_height, max_slope: f32,
}
Default_Bake_Settings_3D :: Bake_Settings_3D{0.5,0.4,2,45}
Bake_Stats_3D :: struct {input_triangles, cells, spans, walkable_cells, output_triangles: int}
destroy_bake_geometry_3d :: proc(g: ^Bake_Geometry_3D) {delete(g.vertices); delete(g.triangles); delete(g.obstacle_triangles); delete(g.solids); g^={}}
bake_settings_valid_3d :: proc(s: Bake_Settings_3D) -> bool {
	return finite_3d(s.cell_size) && s.cell_size>=0.01 && s.cell_size<=1000 &&
		finite_3d(s.agent_radius) && s.agent_radius>=0 && s.agent_radius<=s.cell_size*32 &&
		finite_3d(s.agent_height) && s.agent_height>0 && s.agent_height<=10000 &&
		finite_3d(s.max_slope) && s.max_slope>=0 && s.max_slope<89
}

Bake_Polygon_3D :: struct {points: [16][3]f32, count: int}
Bake_Patch_3D :: struct {polygon: Bake_Polygon_3D, low,high: f32, walkable: bool}
Bake_Span_3D :: struct {first,last: int, low,high: f32, valid,keep: bool, points: [5][3]f32}
Bake_Cell_3D :: struct {patches: [dynamic]Bake_Patch_3D, spans: [dynamic]Bake_Span_3D}
Bake_Epsilon_3D :: f32(0.0001)

// Clip a convex polygon to dot(p-origin, normal) >= 0.
bake_clip_3d :: proc(p: Bake_Polygon_3D, origin,normal: [3]f32) -> Bake_Polygon_3D {
	out: Bake_Polygon_3D
	if p.count==0 {return out}
	previous:=p.points[p.count-1]; a:=dot_3d(previous-origin,normal)
	for i in 0..<p.count {
		current:=p.points[i]
		b:=dot_3d(current-origin,normal)
		if (a>=0)!=(b>=0) {
			if out.count>=16 {return {}}
			out.points[out.count]=previous+(current-previous)*(a/(a-b)); out.count+=1
		}
		if b>=0 {if out.count>=16 {return {}};out.points[out.count]=current;out.count+=1}
		previous=current;a=b
	}
	return out
}
bake_polygon_area_3d :: proc(p: Bake_Polygon_3D) -> f32 {
	area:f32
	for i in 1..<p.count-1 {area+=area_xz(p.points[0],p.points[i],p.points[i+1])}
	return abs(area)*0.5
}
bake_inside_triangle_xz_3d :: proc(p,a,b,c:[3]f32) -> bool {
	positive,negative:=false,false
	vertices:=[3][3]f32{a,b,c}
	for i in 0..<3 {
		u,v:=vertices[i],vertices[(i+1)%3]
		area:=area_xz(u,v,p)
		// Scale tolerance with edge length, rather than triangle area, so
		// small bake cells cannot extrapolate from unrelated terrain faces.
		tolerance:=f32(1e-5)*math.sqrt((v.x-u.x)*(v.x-u.x)+(v.z-u.z)*(v.z-u.z))
		positive=positive || area>tolerance;negative=negative || area < -tolerance
	}
	return !(positive && negative)
}

// Exact union coverage, using convex subtraction. Partial boundary cells are
// discarded; a tiny triangle or overlapping duplicate cannot invent support.
bake_covered_3d :: proc(cell: ^Bake_Cell_3D, span: Bake_Span_3D, square: Bake_Polygon_3D, a: mem.Allocator) -> bool {
	remaining:=make([dynamic]Bake_Polygon_3D,0,8,a);defer delete(remaining)
	next:=make([dynamic]Bake_Polygon_3D,0,8,a);defer delete(next)
	append(&remaining,square)
	for patch in cell.patches[span.first:span.last] {
		if !patch.walkable || bake_polygon_area_3d(patch.polygon)<1e-10 {continue}
		clear(&next)
		for polygon in remaining {
			inside:=polygon
			p:=patch.polygon
			sign:f32=1
			area:f32
			for i in 1..<p.count-1 {area+=area_xz(p.points[0],p.points[i],p.points[i+1])}
			if area<0 {sign=-1}
			for i in 0..<p.count {
				u,v:=p.points[i],p.points[(i+1)%p.count]
				normal:=[3]f32{-(v.z-u.z)*sign,0,(v.x-u.x)*sign}
				if dot_3d(normal,normal)<1e-12 {continue}
				outside:=bake_clip_3d(inside,u,-normal)
				if bake_polygon_area_3d(outside)>1e-9 {append(&next,outside)}
				inside=bake_clip_3d(inside,u,normal)
			}
		}
		remaining,next=next,remaining
		if len(remaining)==0 {return true}
		if len(remaining)>128 {return false} // Conservative complexity limit.
	}
	area:f32;for p in remaining {area+=bake_polygon_area_3d(p)}
	return area<=bake_polygon_area_3d(square)*1e-6
}
bake_height_3d :: proc(cell: ^Bake_Cell_3D, span: Bake_Span_3D, p: [3]f32, lowest:=false) -> (f32,bool) {
	height:f32=1e9 if lowest else -1e9;found:=false
	for patch in cell.patches[span.first:span.last] {
		if !patch.walkable {continue}
		poly:=patch.polygon
		for i in 1..<poly.count-1 {
			a,b,c:=poly.points[0],poly.points[i],poly.points[i+1]
			n:=cross_3d(b-a,c-a)
			if abs(n.y)<1e-10 || !bake_inside_triangle_xz_3d(p,a,b,c) {continue}
			y:=a.y-(n.x*(p.x-a.x)+n.z*(p.z-a.z))/n.y
			height=min(height,y) if lowest else max(height,y);found=true
		}
	}
	return height,found
}

// A conservative layered heightfield bake. No graphics/physics context needed.
// Output uses sampled world heights, with four triangles per surviving cell.
// Temporary storage is released on every return; successful meshes are owned.
bake_mesh_3d :: proc(g: Bake_Geometry_3D, s:=Default_Bake_Settings_3D) -> (mesh: Mesh_3D, stats: Bake_Stats_3D, error: string) {
	if !bake_settings_valid_3d(s) {return {},{},"invalid bake settings (radius must be at most 32 cells)"}
	if len(g.vertices)<3 || len(g.vertices)>6000000 || len(g.triangles)==0 || len(g.triangles)>2000000 {return {},{},"bake needs 3..6000000 vertices and 1..2000000 source triangles"}
	lo:=[3]f32{1e9,1e9,1e9};hi := -lo
	for p in g.vertices {
		if !finite_point_3d(p) || abs(p.x)>1e6 || abs(p.y)>1e6 || abs(p.z)>1e6 {return {},{},"invalid bake vertex"}
		for axis in 0..<3 {lo[axis]=min(lo[axis],p[axis]);hi[axis]=max(hi[axis],p[axis])}
	}
	for t in g.triangles {for i in t {if i<0 || int(i)>=len(g.vertices) {return {},{},"bake index out of bounds"}}}
	for solid in g.solids {
		if solid.first<0 || solid.last<=solid.first || solid.last>len(g.triangles) || !finite_point_3d(solid.low) || !finite_point_3d(solid.high) {return {},{},"invalid solid source bounds"}
	}
	origin:=[3]f32{math.floor(lo.x/s.cell_size)*s.cell_size,0,math.floor(lo.z/s.cell_size)*s.cell_size}
	w,h:=int(math.ceil((hi.x-origin.x)/s.cell_size)),int(math.ceil((hi.z-origin.z)/s.cell_size))
	if w<=0 || h<=0 || w>1048576 || h>1048576 || i64(w)*i64(h)>1048576 {return {},{},"bake grid exceeds 1048576 cells; increase cell_size or split the level"}
	arena:mem.Dynamic_Arena;mem.dynamic_arena_init(&arena);defer mem.dynamic_arena_destroy(&arena)
	a:=mem.dynamic_arena_allocator(&arena)
	cells:=make([]Bake_Cell_3D,w*h,a)
	stats.input_triangles=len(g.triangles);stats.cells=len(cells)
	cosine:=math.cos(s.max_slope*math.PI/180)
	patch_count:=0
	for t,triangle_index in g.triangles {
		p,q,r:=g.vertices[t[0]],g.vertices[t[1]],g.vertices[t[2]]
		n:=cross_3d(q-p,r-p);length:=length_3d(n)
		if length<1e-9 {continue}
		walkable:=n.y/length>=cosine-1e-6 && !g.obstacle_triangles[triangle_index]
		min_x,max_x:=min(p.x,q.x,r.x),max(p.x,q.x,r.x)
		min_z,max_z:=min(p.z,q.z,r.z),max(p.z,q.z,r.z)
		// Include both cells along exact edges, so thin walls block both sides.
		x0:=max(0,int(math.floor((min_x-origin.x)/s.cell_size-1e-5)))
		x1:=min(w-1,int(math.floor((max_x-origin.x)/s.cell_size)))
		z0:=max(0,int(math.floor((min_z-origin.z)/s.cell_size-1e-5)))
		z1:=min(h-1,int(math.floor((max_z-origin.z)/s.cell_size)))
		for z in z0..=z1 {for x in x0..=x1 {
			xmin,zmin:=origin.x+f32(x)*s.cell_size,origin.z+f32(z)*s.cell_size
			poly:=Bake_Polygon_3D{points={0=p,1=q,2=r},count=3}
			poly=bake_clip_3d(poly,{xmin,0,0},{1,0,0})
			poly=bake_clip_3d(poly,{xmin+s.cell_size,0,0},{-1,0,0})
			poly=bake_clip_3d(poly,{0,0,zmin},{0,0,1})
			poly=bake_clip_3d(poly,{0,0,zmin+s.cell_size},{0,0,-1})
			if poly.count==0 || (walkable && bake_polygon_area_3d(poly)<1e-9) {continue}
			patch:=Bake_Patch_3D{polygon=poly,low=1e9,high=-1e9,walkable=walkable}
			for v in poly.points[:poly.count] {patch.low=min(patch.low,v.y);patch.high=max(patch.high,v.y)}
			cell:=&cells[z*w+x]
			if cell.patches.allocator.procedure==nil {cell.patches=make([dynamic]Bake_Patch_3D,0,8,a)}
			append(&cell.patches,patch);patch_count+=1
			if patch_count>4000000 || len(cell.patches)>4096 {return {},stats,"bake rasterization limit exceeded; simplify geometry or split the level"}
		}}
	}
	for &cell,index in cells {
		if len(cell.patches)==0 {continue}
		slice.sort_by(cell.patches[:],proc(a,b:Bake_Patch_3D)->bool {return a.low<b.low || (a.low==b.low && a.high<b.high)})
		cell.spans=make([dynamic]Bake_Span_3D,0,4,a)
		for patch,i in cell.patches {
			if len(cell.spans)==0 || patch.low>cell.spans[len(cell.spans)-1].high+Bake_Epsilon_3D {
				append(&cell.spans,Bake_Span_3D{first=i,last=i+1,low=patch.low,high=patch.high,valid=patch.walkable})
			} else {
				span:=&cell.spans[len(cell.spans)-1];span.last=i+1;span.high=max(span.high,patch.high);span.valid=span.valid && patch.walkable
			}
		}
		stats.spans+=len(cell.spans)
		x,z:=index%w,index/w
		xmin,zmin:=origin.x+f32(x)*s.cell_size,origin.z+f32(z)*s.cell_size
		square:=Bake_Polygon_3D{points={0={xmin,0,zmin},1={xmin+s.cell_size,0,zmin},2={xmin+s.cell_size,0,zmin+s.cell_size},3={xmin,0,zmin+s.cell_size}},count=4}
		for &span,i in cell.spans {
			// A side face ending at a floor is support, not a wall above it.
			// This lets abutting solids and ramp/floor seams remain connected.
			span.valid=true
			if i+1<len(cell.spans) && cell.spans[i+1].low-span.high<s.agent_height {span.valid=false;continue}
			if !bake_covered_3d(&cell,span,square,a) {span.valid=false;continue}
			for patch in cell.patches[span.first:span.last] {
				if patch.walkable {continue}
				for j in 0..<patch.polygon.count {
					p:=patch.polygon.points[j]
					support,found:=bake_height_3d(&cell,span,p,lowest=true)
					if !found || p.y>support+Bake_Epsilon_3D {span.valid=false;break}
				}
			}
			if !span.valid {continue}
			for j in 0..<5 {
				p:=square.points[j] if j<4 else [3]f32{xmin+s.cell_size*0.5,0,zmin+s.cell_size*0.5}
				y,ok:=bake_height_3d(&cell,span,p);span.valid=span.valid && ok;p.y=y;span.points[j]=p
			}
			for j in 0..<4 {
				n:=cross_3d(span.points[4]-span.points[j],span.points[(j+1)%4]-span.points[j])
				if n.y/length_3d(n)<cosine-1e-6 {span.valid=false}
			}
			if span.valid {for p in span.points {if bake_inside_solid_3d(g,p+[3]f32{0,0.001,0}) {span.valid=false;break}}}
		}
	}
	// Each square ring removes at least one cell_size of clearance in every
	// horizontal direction. This intentionally over-erodes diagonal corners.
	rings:=int(math.ceil(s.agent_radius/s.cell_size))
	for _ in 0..<rings {
		for &cell,index in cells {for &span in cell.spans {
			span.keep=span.valid
			if !span.valid {continue}
			x,z:=index%w,index/w
			for dz in -1..=1 {for dx in -1..=1 {
				if dx==0 && dz==0 {continue}
				nx,nz:=x+dx,z+dz
				if nx<0 || nx>=w || nz<0 || nz>=h {span.keep=false;continue}
				connected:=false
				for neighbor in cells[nz*w+nx].spans {
					if !neighbor.valid {continue}
					matches:=0
					for p in span.points[:4] {for j in 0..<4 {q:=neighbor.points[j]
						if abs(p.x-q.x)<Bake_Epsilon_3D && abs(p.z-q.z)<Bake_Epsilon_3D && abs(p.y-q.y)<Bake_Epsilon_3D {matches+=1}
					}}
					if matches >= (2 if dx==0 || dz==0 else 1) {connected=true;break}
				}
				if !connected {span.keep=false}
			}}
		}}
		for &cell in cells {for &span in cell.spans {span.valid=span.keep}}
	}
	vertices:=make([dynamic][3]f32,0,1024,a);triangles:=make([dynamic][3]i32,0,1024,a)
	// Search neighboring height buckets to weld roundoff at sample seams.
	weld:=make(map[[3]i64]i32,a)
	for cell in cells {for span in cell.spans {
		if !span.valid {continue};stats.walkable_cells+=1
		indices:[5]i32
		for p,i in span.points {
			key:=[3]i64{i64(math.round((p.x-origin.x)/s.cell_size*2)),i64(math.floor(p.y/Bake_Epsilon_3D)),i64(math.round((p.z-origin.z)/s.cell_size*2))}
			index:i32=-1
			for dy in -1..=1 {
				candidate,exists:=weld[[3]i64{key[0],key[1]+i64(dy),key[2]}]
				if exists && abs(vertices[candidate].y-p.y)<Bake_Epsilon_3D {index=candidate;break}
			}
			if index<0 {
				index=i32(len(vertices));append(&vertices,p)
				weld[key]=index
			}
			indices[i]=index
		}
		for j in 0..<4 {append(&triangles,[3]i32{indices[j],indices[4],indices[(j+1)%4]})}
		if len(triangles)>65536 {return {},stats,"baked mesh exceeds 65536 triangles; increase cell_size or split the level"}
	}}
	stats.output_triangles=len(triangles)
	if len(triangles)==0 {return {},stats,"no walkable surface remains after slope, headroom and radius filtering"}
	mesh,error=build_mesh_3d({version=1,agent_radius=s.agent_radius,agent_height=s.agent_height,vertices=vertices[:],triangles=triangles[:]})
	return
}

// Closed source volumes can bury terrain/floors without their side triangles
// crossing an interior cell. Test upward winding crossings to reject those
// buried surfaces. Coincident hits on a shared edge count only once.
bake_inside_solid_3d :: proc(g:Bake_Geometry_3D,p:[3]f32) -> bool {
	for solid in g.solids {
		if p.x<solid.low.x || p.x>solid.high.x || p.z<solid.low.z || p.z>solid.high.z || p.y<solid.low.y || p.y>=solid.high.y {continue}
		hits:[128][2]f32;count:=0
		for t in g.triangles[solid.first:solid.last] {
			a,b,c:=g.vertices[t[0]],g.vertices[t[1]],g.vertices[t[2]]
			n:=cross_3d(b-a,c-a)
			if abs(n.y)<1e-10 || !bake_inside_triangle_xz_3d(p,a,b,c) {continue}
			y:=a.y-(n.x*(p.x-a.x)+n.z*(p.z-a.z))/n.y
			if y<=p.y {continue}
			sign:f32=1 if n.y>0 else -1
			duplicate:=false
			for i in 0..<count {if abs(hits[i][0]-y)<Bake_Epsilon_3D && hits[i][1]==sign {duplicate=true;break}}
			if !duplicate {
				if count>=len(hits) {return true} // Fail closed on pathological geometry.
				hits[count]={y,sign};count+=1
			}
		}
		winding:f32;for i in 0..<count {winding+=hits[i][1]}
		if winding>0 {return true}
	}
	return false
}

// Serialize a completed bake to the same asset format as authored meshes.
write_mesh_3d :: proc(path: string, mesh: ^Mesh_3D) -> string {
	indices:=make([][3]i32,len(mesh.triangles));defer delete(indices)
	for t,i in mesh.triangles {indices[i]=t.vertices}
	data:=Mesh_Data_3D{1,mesh.agent_radius,mesh.agent_height,mesh.vertices,indices}
	checked,error:=build_mesh_3d(data)
	if error!="" {return error};destroy_mesh_3d(&checked)
	bytes,err:=json.marshal(data);defer delete(bytes)
	if err!=nil {return "could not encode navmesh"}
	f,open_error:=os.create_temp_file(filepath.dir(path),".navmesh-*.tmp")
	if open_error!=nil {return "could not create temporary navmesh; output directory must exist"}
	temporary:=strings.clone(os.name(f)) or_else "";defer delete(temporary);defer os.remove(temporary)
	written,write_error:=os.write(f,bytes)
	flushed:=os.sync(f)==nil
	closed:=os.close(f)==nil
	if write_error!=nil || written!=len(bytes) || !flushed || !closed {return "could not finish navmesh write; previous asset retained"}
	if os.rename(temporary,path)!=nil {return "could not replace navmesh; previous asset retained"}
	return ""
}
