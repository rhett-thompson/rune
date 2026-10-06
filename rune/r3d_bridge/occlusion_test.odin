package r3d_bridge

import "core:testing"
import "core:math"
import "rune:geometry"
import rl "vendor:raylib"

@(test)
occlusion_uses_only_real_opaque_convex_faces :: proc(t:^testing.T) {
	mesh:geometry.Mesh; defer geometry.destroy_mesh(&mesh)
	for p in ([4][3]f32{{-2,-2,-3},{2,-2,-3},{2,2,-3},{-2,2,-3}}) {append(&mesh.vertices,geometry.Vertex{position=p,color={255,255,255,255}})}
	append(&mesh.indices,0,1,2,0,2,3)
	faces:=extract_occlusion_faces(mesh); defer delete(faces)
	testing.expect(t,len(faces)==1 && faces[0].count==4,"triangle diagonal must not create a visibility gap")
	mesh.vertices[3].position[2]=-2.999
	nonplanar:=extract_occlusion_faces(mesh); defer delete(nonplanar)
	testing.expect(t,len(nonplanar)==2 && nonplanar[0].count==3 && nonplanar[1].count==3,"nearly coplanar triangles cannot fill space between their surfaces")
	mesh.vertices[3].position={0,0,-3}
	concave:=extract_occlusion_faces(mesh); defer delete(concave)
	for face in concave {testing.expect(t,face.count==3,"concave geometry cannot fill a hole")}
	for &v in mesh.vertices {v.color[3]=128}
	transparent:=extract_occlusion_faces(mesh); defer delete(transparent)
	testing.expect(t,len(transparent)==0,"vertex alpha must not hide other geometry")
}

@(test)
occlusion_retains_near_edges_gaps_and_wrong_depth :: proc(t:^testing.T) {
	projection:=rl.MatrixPerspective(60*math.PI/180,1,0.1,100)
	identity:=rl.Matrix(1)
	face:=Occlusion_Face{count=4,points={{-1.2,-1.2,-3},{1.2,-1.2,-3},{1.2,1.2,-3},{-1.2,1.2,-3}}}
	projected,valid:=project_occlusion_face(face,identity,projection,{},.BACK)
	testing.expect(t,valid)
	state:=Occlusion_State{view_projection=projection,width=320,height=320,count=1}
	state.occluders[0]=projected
	testing.expect(t,bounds_occluded({{-0.5,-0.5,-7},{0.5,0.5,-6}},&state),"small bounds wholly behind an opaque face are hidden")
	testing.expect(t,!bounds_occluded({{-0.5,-0.5,-2},{0.5,0.5,-1}},&state),"foreground geometry is visible")
	testing.expect(t,!bounds_occluded({{-0.5,-0.5,-4},{0.5,0.5,-3}},&state),"coplanar geometry and the occluder itself remain visible")
	testing.expect(t,!bounds_occluded({{-0.5,-0.5,-1},{0.5,0.5,0.1}},&state),"near-plane intersections fail open")
	testing.expect(t,!bounds_occluded({{2.2,-0.5,-7},{2.7,0.5,-6}},&state),"partly exposed silhouettes cannot be culled")
	_,valid=project_occlusion_face(face,identity,projection,{},.FRONT)
	testing.expect(t,!valid,"culled sides cannot occlude")
	near_face:=face; for &p in near_face.points {p[2]=-0.05}
	_,valid=project_occlusion_face(near_face,identity,projection,{},.BACK)
	testing.expect(t,!valid,"near-clipped occluders are ignored")
	// A wall split around a doorway must retain a mesh viewed through it.
	state.count=2
	left:=face; left.points[1][0]=-0.75; left.points[2][0]=-0.75
	right:=face; right.points[0][0]=0.75; right.points[3][0]=0.75
	state.occluders[0],_=project_occlusion_face(left,identity,projection,{},.BACK)
	state.occluders[1],_=project_occlusion_face(right,identity,projection,{},.BACK)
	testing.expect(t,!bounds_occluded({{-0.5,-0.5,-7},{0.5,0.5,-6}},&state),"a doorway remains open in the visibility proof")
}
