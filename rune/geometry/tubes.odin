// Capped circular tubes along caller-sampled paths; curve/layout rules stay with callers.
package geometry

import "core:math"
import "core:math/linalg"

// Append independent tube geometry. Existing vertices and indices stay unchanged
// on failure. The path needs at least two distinct consecutive points; exact
// reversals cannot define a bend ring. Callers own mesh's persistent allocations.
append_tube :: proc(mesh: ^Mesh, points: [][3]f32, radius: f32, sides: int = 8, color: [4]u8 = {255,255,255,255}) -> bool {
	if mesh==nil || len(points)<2 || len(points)>65536 || sides<3 || sides>64 || !(radius>0 && radius<=1e6) {return false}
	if len(mesh.vertices)>0 || len(mesh.indices)>0 {if !valid(mesh^) {return false}}
	vertex_count:=len(points)*sides+2*(sides+1)
	index_count:=(len(points)-1)*sides*6+2*sides*3
	if len(mesh.vertices)+vertex_count>1000000 || len(mesh.indices)+index_count>6000000 {return false}
	for p in points {for n in p {if !(n>=-1e6 && n<=1e6) {return false}}}
	directions:=make([][3]f32,len(points)-1)
	defer delete(directions)
	for &direction,i in directions {
		delta:=points[i+1]-points[i]
		length:=linalg.length(delta)
		if !(length>1e-5) {return false}
		direction=delta/length
	}
	for i in 1..<len(points)-1 {
		if linalg.dot(directions[i-1],directions[i])<=-0.9999 {return false}
	}
	// Build separately so invalid output (e.g. a radius that folds a tight bend)
	// cannot leave a partly appended mesh or changed buffer ownership behind.
	tube: Mesh
	defer destroy_mesh(&tube)
	reserve(&tube.vertices,vertex_count); reserve(&tube.indices,index_count)
	axis,previous_tangent: [3]f32
	first_tangent,last_tangent: [3]f32
	for p,i in points {
		tangent:=directions[0] if i==0 else directions[len(directions)-1]
		if i>0 && i<len(points)-1 {tangent=linalg.normalize(directions[i-1]+directions[i])}
		if i==0 {
			first_tangent=tangent
			// Choose the least parallel reference axis, including vertical paths.
			index:=0
			for j in 1..<3 {if abs(tangent[j])<abs(tangent[index]) {index=j}}
			reference: [3]f32; reference[index]=1
			axis=linalg.normalize(linalg.cross(reference,tangent))
		} else {
			// Parallel transport rotates the previous ring by the shortest turn;
			// unlike a fixed up vector, this also stays stable at vertical bends.
			rotation_axis:=linalg.cross(previous_tangent,tangent)
			cosine:=linalg.dot(previous_tangent,tangent)
			if cosine<=-0.9999 {return false}
			turn:=linalg.cross(rotation_axis,axis)
			axis=linalg.normalize(axis+turn+linalg.cross(rotation_axis,turn)/(1+cosine))
		}
		previous_tangent=tangent
		last_tangent=tangent
		second:=linalg.cross(tangent,axis)
		for side in 0..<sides {
			angle:=f32(2*math.PI)*f32(side)/f32(sides)
			normal:=axis*math.cos(angle)+second*math.sin(angle)
			append(&tube.vertices,Vertex{position=p+normal*radius,normal=normal,color=color})
		}
	}
	for i in 0..<len(points)-1 {for side in 0..<sides {
		a:=u32(i*sides+side); b:=u32(i*sides+(side+1)%sides)
		c,d:=b+u32(sides),a+u32(sides)
		append(&tube.indices,a,b,c,a,c,d)
	}}
	// Separate cap rings keep endpoint normals flat rather than shading across
	// the sharp rim. Their positions exactly match the side rings for welding.
	for end in 0..<2 {
		ring:=0 if end==0 else (len(points)-1)*sides
		normal:=-first_tangent if end==0 else last_tangent
		center:=u32(len(tube.vertices))
		append(&tube.vertices,Vertex{position=points[0] if end==0 else points[len(points)-1],normal=normal,color=color})
		for side in 0..<sides {append(&tube.vertices,Vertex{position=tube.vertices[ring+side].position,normal=normal,color=color})}
		for side in 0..<sides {
			a,b:=center+1+u32(side),center+1+u32((side+1)%sides)
			if end==0 {append(&tube.indices,center,b,a)} else {append(&tube.indices,center,a,b)}
		}
	}
	if !valid(tube) {return false}
	for i:=0; i<len(tube.indices); i+=3 {
		a,b,c:=tube.vertices[tube.indices[i]],tube.vertices[tube.indices[i+1]],tube.vertices[tube.indices[i+2]]
		if linalg.dot(linalg.cross(b.position-a.position,c.position-a.position),a.normal+b.normal+c.normal)<=0 {return false}
	}
	base:=u32(len(mesh.vertices))
	append(&mesh.vertices,..tube.vertices[:])
	for index in tube.indices {append(&mesh.indices,base+index)}
	return true
}
