package main

import "core:math"
import rl "vendor:raylib"

STAR_COUNT :: 500
FLIGHT_DOT_COUNT :: 16
SPHERE_RINGS :: 16
SPHERE_SLICES :: 16
SPHERE_VERTEX_COUNT :: (SPHERE_RINGS+1)*SPHERE_SLICES*6

scenery_mesh: rl.Mesh
scenery_material: rl.Material

// Match DrawSphere's geometry once, instead of rebuilding its triangles for
// every star and flight dot on every frame.
scenery_sphere_vertices :: proc()->[SPHERE_VERTEX_COUNT]V3 {
	vertices:[SPHERE_VERTEX_COUNT]V3
	ring_angle:=f32(math.PI/(SPHERE_RINGS+1))
	slice_angle:=f32(math.TAU/SPHERE_SLICES)
	cr,sr:=math.cos(ring_angle),math.sin(ring_angle)
	cs,ss:=math.cos(slice_angle),math.sin(slice_angle)
	v2,v3:=V3{0,1,0},V3{sr,cr,0}
	cursor:=0
	for _ in 0..<SPHERE_RINGS+1 {
		for _ in 0..<SPHERE_SLICES {
			v0,v1:=v2,v3
			v2={cs*v2[0]-ss*v2[2],v2[1],ss*v2[0]+cs*v2[2]}
			v3={cs*v3[0]-ss*v3[2],v3[1],ss*v3[0]+cs*v3[2]}
			for v in ([6]V3{v0,v3,v1,v0,v2,v3}) {
				vertices[cursor]=v;cursor+=1
			}
		}
		v2=v3
		v3={cr*v3[0]+sr*v3[1],-sr*v3[0]+cr*v3[1],v3[2]}
	}
	return vertices
}

scenery_vertex :: proc(mesh:^rl.Mesh,cursor:^int,position:V3,color:rl.Color) {
	i:=cursor^
	for value,axis in position {mesh.vertices[i*3+axis]=value}
	mesh.colors[i*4+0]=color.r;mesh.colors[i*4+1]=color.g
	mesh.colors[i*4+2]=color.b;mesh.colors[i*4+3]=color.a
	cursor^+=1
}

create_scenery :: proc() {
	destroy_scenery()
	if !rl.IsWindowReady() {return}
	vertex_count:=SPHERE_VERTEX_COUNT*(STAR_COUNT+len(PLANETS)*FLIGHT_DOT_COUNT)
	for mesh in meshes {vertex_count+=len(mesh.indices)}
	// Non-indexed geometry retains each terrain face's color and avoids the
	// 16-bit index limit for the combined star field. UnloadMesh owns these arrays.
	positions:=make([]f32,vertex_count*3,rl.MemAllocator())
	colors:=make([]u8,vertex_count*4,rl.MemAllocator())
	scenery_mesh={vertexCount=i32(vertex_count),triangleCount=i32(vertex_count/3),
		vertices=raw_data(positions),colors=raw_data(colors)}
	sphere:=scenery_sphere_vertices()
	cursor:=0
	for j in 0..<STAR_COUNT {
		a:=f32(j)*2.399963
		y:=1-2*(f32(j)+0.5)/STAR_COUNT
		r:=math.sqrt(1-y*y)
		center:=V3{r*math.cos(a),y,r*math.sin(a)}*210
		radius:=0.1+f32(j%4)*0.04
		for v in sphere {scenery_vertex(&scenery_mesh,&cursor,center+v*radius,{145,166,204,255})}
	}
	light_direction:=unit({-0.5,0.9,0.6})
	for planet,i in PLANETS {
		mesh:=&meshes[i]
		for j:=0;j<len(mesh.indices);j+=3 {
			a,b,c:=mesh.vertices[mesh.indices[j]],mesh.vertices[mesh.indices[j+1]],mesh.vertices[mesh.indices[j+2]]
			n:=unit(cross(b-a,c-a))
			height:=(length((a+b+c)/3)-planet.radius*0.79)/max(planet.relief*1.4,0.1)
			light:=0.58+0.42*max(0,dot(n,light_direction))
			color:=mix_color(planet.low,planet.high,height,light)
			for v in ([3]V3{a,b,c}) {scenery_vertex(&scenery_mesh,&cursor,v+planet.center,color)}
		}
		up:=gate_direction(i);gate:=gates[i]
		next:=(i+1)%len(PLANETS)
		end:=PLANETS[next].center-up*(PLANETS[next].radius+0.6)
		for k in 0..<FLIGHT_DOT_COUNT {
			t:=f32(k)/FLIGHT_DOT_COUNT
			center:=gate+up*2+(end-gate-up*2)*t
			for v in sphere {scenery_vertex(&scenery_mesh,&cursor,center+v*0.055,rl.Fade(GOLD,0.8))}
		}
	}
	assert(cursor==vertex_count)
	rl.UploadMesh(&scenery_mesh,false)
	scenery_material=rl.LoadMaterialDefault()
}

destroy_scenery :: proc() {
	if scenery_mesh.vertices!=nil {rl.UnloadMesh(scenery_mesh)}
	if scenery_material.maps!=nil {rl.UnloadMaterial(scenery_material)}
	scenery_mesh={};scenery_material={}
}
