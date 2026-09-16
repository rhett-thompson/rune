package r3d_bridge

import "core:math"
import "core:math/linalg"
import "rune:terrain"
import r3d "r3d:r3d"
import rl "vendor:raylib"

detail_triangle :: proc(vertices:^[dynamic]r3d.Vertex,a,b,c:[3]f32,color:rl.Color) {
	n:=linalg.normalize(linalg.cross(b-a,c-a))
	t:=linalg.normalize(b-a)
	append(vertices,r3d.MakeVertex(a,{0,0},n,{t[0],t[1],t[2],1},color),
		r3d.MakeVertex(b,{1,0},n,{t[0],t[1],t[2],1},color),
		r3d.MakeVertex(c,{0.5,1},n,{t[0],t[1],t[2],1},color))
}

detail_cone :: proc(vertices:^[dynamic]r3d.Vertex,bottom,top,radius,top_radius:f32,color:rl.Color) {
	for i in 0..<8 {
		a,b:=f32(i)*f32(math.PI)/4,f32(i+1)*f32(math.PI)/4
		p:=[3]f32{math.cos(a)*radius,bottom,math.sin(a)*radius}
		q:=[3]f32{math.cos(b)*radius,bottom,math.sin(b)*radius}
		u:=[3]f32{math.cos(a)*top_radius,top,math.sin(a)*top_radius}
		v:=[3]f32{math.cos(b)*top_radius,top,math.sin(b)*top_radius}
		detail_triangle(vertices,p,u,q,color)
		if top_radius>0 {detail_triangle(vertices,q,u,v,color)}
		detail_triangle(vertices,{0,bottom,0},p,q,color)
	}
}

make_detail_mesh :: proc(kind:int) -> r3d.Mesh {
	vertices:=make([dynamic]r3d.Vertex); defer delete(vertices)
	if kind==0 {
		for i in 0..<7 {
			angle:=f32(i)*2.4
			right:=[3]f32{math.cos(angle),0,math.sin(angle)}
			base:=right*(0.07+f32(i%3)*0.06)
			height:=0.35+0.25*terrain.detail_random(57,u32(i),0)
			width:=0.025+0.015*terrain.detail_random(57,u32(i),1)
			mid:=base+right*0.04+[3]f32{0,height*0.6,0}
			tip:=base+right*0.13+[3]f32{0,height,0}
			detail_triangle(&vertices,base-right*width,base+right*width,mid-right*width*0.65,{42,91,24,255})
			detail_triangle(&vertices,base+right*width,mid+right*width*0.65,mid-right*width*0.65,{59,114,31,255})
			detail_triangle(&vertices,mid-right*width*0.65,mid+right*width*0.65,tip,{104,150,47,255})
		}
	} else if kind==1 {
		detail_cone(&vertices,0,3.6,0.2,0.1,{92,59,32,255})
		detail_cone(&vertices,1.25,3.7,1.3,0,{32,75,38,255})
		detail_cone(&vertices,2.25,4.5,1.0,0,{40,90,42,255})
		detail_cone(&vertices,3.2,5.2,0.7,0,{52,108,47,255})
	} else {
		rings:[3][7][3]f32
		for ring in 0..<3 {for i in 0..<7 {
			angle:=f32(i)*2*f32(math.PI)/7
			radius:=(0.58 if ring==0 else (1.0 if ring==1 else 0.55))*(0.85+terrain.detail_random(183,u32(i),u32(ring))*0.3)
			rings[ring][i]={math.cos(angle)*radius,0 if ring==0 else (0.4 if ring==1 else 0.95),math.sin(angle)*radius*0.8}
		}}
		for i in 0..<7 {
			next:=(i+1)%7
			for ring in 0..<2 {
				detail_triangle(&vertices,rings[ring][i],rings[ring+1][i],rings[ring][next],{122,126,124,255})
				detail_triangle(&vertices,rings[ring][next],rings[ring+1][i],rings[ring+1][next],{142,144,137,255})
			}
			detail_triangle(&vertices,rings[2][i],{0.08,1.13,-0.07},rings[2][next],{153,154,143,255})
		}
	}
	return r3d.LoadMesh(.TRIANGLES,{vertices=raw_data(vertices),vertexCount=i32(len(vertices)),vertexCapacity=i32(len(vertices))},nil)
}
