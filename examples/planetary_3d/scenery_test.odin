package main

import "core:math"
import "core:testing"

@(test)
scenery_sphere_geometry :: proc(t:^testing.T) {
	vertices:=scenery_sphere_vertices()
	north_pole,south_pole,north_surface,south_surface:bool
	for v in vertices {
		for coordinate in v {
			testing.expect(t,!math.is_nan(coordinate) && !math.is_inf(coordinate),"sphere positions are finite")
		}
		// Incremental f32 rotation accumulates a small amount of roundoff.
		testing.expect(t,math.abs(dot(v,v)-1)<0.0001,"sphere vertices remain on the unit surface")
		if v[1]>0.9999 {north_pole=true}
		if v[1]<-0.9999 {south_pole=true}
		if v[1]>0.1 && v[1]<0.99 {north_surface=true}
		if v[1]<-0.1 && v[1]>-0.99 {south_surface=true}
	}
	testing.expect(t,north_pole && south_pole,"sphere reaches both poles")
	testing.expect(t,north_surface && south_surface,"sphere covers both hemispheres between the poles")
	for j:=0;j<len(vertices);j+=3 {
		a,b,c:=vertices[j],vertices[j+1],vertices[j+2]
		normal:=cross(b-a,c-a)
		if dot(normal,normal)>0.000000000001 {
			testing.expect(t,dot(normal,a+b+c)>0,"sphere triangles face outward")
		} else {
			// The latitude grid collapses one triangle of each polar quad.
			poles:=0
			for v in ([3]V3{a,b,c}) {if math.abs(v[1])>0.9999 {poles+=1}}
			testing.expect(t,poles>=2,"collapsed triangles are confined to the poles")
		}
	}
}
