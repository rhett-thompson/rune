package navigation

import "core:mem"
import "core:slice"

Bake_Output_Cell_3D :: struct {cell_index: int, points: [5]i32}
Bake_Rectangle_3D :: struct {
	x0,z0,x1,z1: int,
	corners: [4]i32,
	center: i32, // Preserve the original center of a nonplanar cell.
}
Bake_Line_Point_3D :: struct {coordinate: int, vertex: i32}
Bake_Lines_3D :: map[[2]int][dynamic]Bake_Line_Point_3D

// Deterministic rectangular decomposition of the already-filtered surface.
// Every merged cell must agree with the seed's fixed plane, preventing error
// from accumulating across rough terrain. Shared corner IDs also require the
// original surface to be connected, including on stacked floors and ramps.
bake_simplify_3d :: proc(vertices: ^[dynamic][3]f32, cells: []Bake_Output_Cell_3D,
	w,h: int, allocator: mem.Allocator) -> ([dynamic][3]i32,string) {
	heads:=make([]int,w*h,allocator);for &head in heads {head=-1}
	next:=make([]int,len(cells),allocator)
	for cell,i in cells {next[i]=heads[cell.cell_index];heads[cell.cell_index]=i}
	used:=make([]bool,len(cells),allocator)
	owners:=make([]int,len(cells),allocator)
	rectangles:=make([dynamic]Bake_Rectangle_3D,0,len(cells),allocator)
	last_row:=make([dynamic]int,0,64,allocator)
	row:=make([dynamic]int,0,64,allocator)
	for seed,i in cells {
		if used[i] {continue}
		x,z:=seed.cell_index%w,seed.cell_index/w
		p:=vertices[seed.points[0]]
		n:=cross_3d(vertices[seed.points[1]]-p,vertices[seed.points[3]]-p)
		planar:=bake_cell_on_plane_3d(vertices[:],seed,p,n)
		owner:=len(rectangles)
		clear(&last_row);append(&last_row,i);used[i]=true;owners[i]=owner
		if planar {
			for nx:=x+1;nx<w;nx+=1 {
				left:=cells[last_row[len(last_row)-1]]
				found:=-1
				for candidate:=heads[z*w+nx];candidate>=0;candidate=next[candidate] {
					c:=cells[candidate]
					if !used[candidate] && c.points[0]==left.points[1] && c.points[3]==left.points[2] && bake_cell_on_plane_3d(vertices[:],c,p,n) {found=candidate;break}
				}
				if found<0 {break}
				append(&last_row,found);used[found]=true;owners[found]=owner
			}
		}
		width:=len(last_row)
		corners:=[4]i32{seed.points[0],cells[last_row[width-1]].points[1],0,0}
		end_z:=z+1
		if planar {for nz:=z+1;nz<h;nz+=1 {
			clear(&row)
			for dx in 0..<width {
				below:=cells[last_row[dx]]
				found:=-1
				for candidate:=heads[nz*w+x+dx];candidate>=0;candidate=next[candidate] {
					c:=cells[candidate]
					if used[candidate] || c.points[0]!=below.points[3] || c.points[1]!=below.points[2] || !bake_cell_on_plane_3d(vertices[:],c,p,n) {continue}
					if dx>0 {
						left:=cells[row[dx-1]]
						if c.points[0]!=left.points[1] || c.points[3]!=left.points[2] {continue}
					}
					found=candidate;break
				}
				if found<0 {break}
				append(&row,found)
			}
			if len(row)!=width {break}
			for candidate in row {used[candidate]=true;owners[candidate]=owner}
			last_row,row=row,last_row;end_z=nz+1
		}}
		corners[2]=cells[last_row[width-1]].points[2];corners[3]=cells[last_row[0]].points[3]
		append(&rectangles,Bake_Rectangle_3D{x,z,x+width,end_z,corners,-1 if planar else seed.points[4]})
	}

	// Register all rectangle corners on their grid lines. Each boundary then
	// includes its neighbor's corners, avoiding T-junctions at small cells,
	// holes, decomposition seams and planar/nonplanar transitions.
	lines:=make(Bake_Lines_3D,allocator)
	for r in rectangles {
		for edge in 0..<4 {
			key,start,end:=bake_rectangle_edge_3d(r,edge)
			line:=lines[key]
			if line.allocator.procedure==nil {line=make([dynamic]Bake_Line_Point_3D,0,8,allocator)}
			append(&line,Bake_Line_Point_3D{start,r.corners[edge]},Bake_Line_Point_3D{end,r.corners[(edge+1)%4]})
			lines[key]=line
		}
	}
	for _,&line in lines {
		slice.sort_by(line[:],proc(a,b:Bake_Line_Point_3D)->bool {return a.coordinate<b.coordinate || (a.coordinate==b.coordinate && a.vertex<b.vertex)})
		count:=0
		for point in line {
			if count>0 && line[count-1]==point {continue}
			line[count]=point;count+=1
		}
		resize(&line,count)
	}
	triangles:=make([dynamic][3]i32,0,len(rectangles)*4,allocator)
	polygon:=make([dynamic]i32,0,64,allocator)
	edge_points:=make([dynamic]i32,0,64,allocator)
	for r,rectangle_index in rectangles {
		clear(&polygon)
		for edge in 0..<4 {
			key,start,end:=bake_rectangle_edge_3d(r,edge)
			append(&polygon,r.corners[edge]);clear(&edge_points)
			line:=lines[key]
			low,high:=0,len(line)
			for low<high {mid:=(low+high)/2;if line[mid].coordinate<=min(start,end) {low=mid+1} else {high=mid}}
			previous:=-1
			for j:=low;j<len(line) && line[j].coordinate<max(start,end);j+=1 {
				point:=line[j]
				if point.coordinate==previous {continue}
				// Use original welded IDs, rather than approximate plane heights,
				// to retain exact seam connections and keep other layers separate.
				cell_index,corner: int
				switch edge {
				case 0: cell_index=r.z0*w+point.coordinate;corner=0
				case 1: cell_index=point.coordinate*w+r.x1-1;corner=1
				case 2: cell_index=(r.z1-1)*w+point.coordinate;corner=3
				case 3: cell_index=point.coordinate*w+r.x0;corner=0
				}
				matches:=false
				for c:=heads[cell_index];c>=0;c=next[c] {
					if owners[c]==rectangle_index && cells[c].points[corner]==point.vertex {matches=true;break}
				}
				if !matches {continue}
				append(&edge_points,point.vertex);previous=point.coordinate
			}
			if start<end {append(&polygon,..edge_points[:])} else {for j:=len(edge_points)-1;j>=0;j-=1 {append(&polygon,edge_points[j])}}
		}
		if len(polygon)==4 && r.center<0 {
			append(&triangles,[3]i32{polygon[0],polygon[2],polygon[1]},[3]i32{polygon[0],polygon[3],polygon[2]})
		} else {
			center:=r.center
			if center<0 {
				center=i32(len(vertices^))
				p:=[3]f32{};for corner in r.corners {p+=vertices[corner]*0.25}
				append(vertices,p)
			}
			for j in 0..<len(polygon) {append(&triangles,[3]i32{polygon[j],center,polygon[(j+1)%len(polygon)]})}
		}
		if len(triangles)>65536 {return {},"baked mesh exceeds 65536 triangles after simplification; increase cell_size or split the level"}
	}
	// Discard the old grid's unused interior vertices before enforcing the
	// asset vertex limit. First-use order keeps the output deterministic.
	remap:=make([]i32,len(vertices^),allocator);for &index in remap {index=-1}
	compact:=make([dynamic][3]f32,0,len(triangles),allocator)
	for &triangle in triangles {for &index in triangle {
		if remap[index]<0 {remap[index]=i32(len(compact));append(&compact,vertices[index])}
		index=remap[index]
	}}
	vertices^=compact
	return triangles,""
}

bake_cell_on_plane_3d :: proc(vertices: [][3]f32, cell:Bake_Output_Cell_3D,p,n:[3]f32) -> bool {
	for index in cell.points {if abs(dot_3d(n,vertices[index]-p))>abs(n.y)*Bake_Epsilon_3D {return false}}
	return true
}

// Grid-line keys use {axis, fixed coordinate}; axis zero runs along X.
bake_rectangle_edge_3d :: proc(r:Bake_Rectangle_3D,edge:int) -> ([2]int,int,int) {
	switch edge {
	case 0: return {0,r.z0},r.x0,r.x1
	case 1: return {1,r.x1},r.z0,r.z1
	case 2: return {0,r.z1},r.x1,r.x0
	case: return {1,r.x0},r.z1,r.z0
	}
}
