package main

import "core:math"
import "rune:ecs"
import b3 "vendor:box3d"
import rl "vendor:raylib"

V3 :: [3]f32
dot :: proc(a,b:V3)->f32 {return a[0]*b[0]+a[1]*b[1]+a[2]*b[2]}
length :: proc(v:V3)->f32 {return math.sqrt(dot(v,v))}
unit :: proc(v:V3)->V3 {n:=length(v);if n<0.00001 {return {0,1,0}};return v/n}
cross :: proc(a,b:V3)->V3 {return {a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]}}
rv :: proc(v:V3)->rl.Vector3 {return {v[0],v[1],v[2]}}
tangent :: proc(v,up:V3)->V3 {return v-up*dot(v,up)}

Planet :: struct {
	name: cstring,
	center: V3,
	radius, relief, seed: f32,
	low, high: rl.Color,
}
PLANETS := [4]Planet {
	{"VERDANT",{0,0,0},8,1.15,0,{35,109,103,255},{144,205,133,255}},
	{"EMBER",{13,17,0},6,0.85,2,{137,62,67,255},{247,181,117,255}},
	{"LILAC",{-3,31,-7},7,1.05,4,{81,69,140,255},{182,159,232,255}},
	{"GLACIER",{-16,14,-7},6,0.8,7,{42,112,151,255},{175,231,237,255}},
}
Planet_Mesh :: struct {
	vertices: [dynamic]V3,
	indices: [dynamic]i32,
	collision: ^b3.MeshData,
	body: b3.BodyId,
	shape: b3.ShapeId,
	entity: ecs.Entity,
}
meshes: [4]Planet_Mesh
rocks:[12]ecs.Entity

// Subdivide each original icosahedron face without rounding away its silhouette.
// Shared vertices are welded before Box3D identifies edges, avoiding seam snags.
mesh_vertex :: proc(mesh:^Planet_Mesh,p:V3)->i32 {
	for v,i in mesh.vertices {if length(v-p)<0.0001 {return i32(i)}}
	append(&mesh.vertices,p)
	return i32(len(mesh.vertices)-1)
}
subdivide :: proc(mesh:^Planet_Mesh,a,b,c:V3,depth:int) {
	if depth>0 {
		ab,bc,ca:=(a+b)*0.5,(b+c)*0.5,(c+a)*0.5
		subdivide(mesh,a,ab,ca,depth-1);subdivide(mesh,ab,b,bc,depth-1)
		subdivide(mesh,ca,bc,c,depth-1);subdivide(mesh,ab,bc,ca,depth-1)
		return
	}
	append(&mesh.indices,mesh_vertex(mesh,a),mesh_vertex(mesh,b),mesh_vertex(mesh,c))
}
build_mesh :: proc(planet:Planet)->Planet_Mesh {
	t:=f32((1+math.sqrt(5.0))/2)
	vertices:=[12]V3{{-1,t,0},{1,t,0},{-1,-t,0},{1,-t,0},{0,-1,t},{0,1,t},
		{0,-1,-t},{0,1,-t},{t,0,-1},{t,0,1},{-t,0,-1},{-t,0,1}}
	faces:=[20][3]int{{0,11,5},{0,5,1},{0,1,7},{0,7,10},{0,10,11},{1,5,9},
		{5,11,4},{11,10,2},{10,7,6},{7,1,8},{3,9,4},{3,4,2},{3,2,6},{3,6,8},
		{3,8,9},{4,9,5},{2,4,11},{6,2,10},{8,6,7},{9,8,1}}
	mesh:Planet_Mesh
	for face in faces {subdivide(&mesh,unit(vertices[face[0]]),unit(vertices[face[1]]),unit(vertices[face[2]]),2)}
	for &v in mesh.vertices {
		n:=unit(v)
		// Low-frequency ridges and a bowl, retaining broad walkable facets.
		h:=math.sin(n[0]*5+planet.seed)*math.cos(n[2]*4-planet.seed)*0.65+
			math.sin(n[1]*6+n[2]*3+planet.seed)*0.35
		crater:=max(0,dot(n,unit({-0.5,0.7,0.5}))-0.78)/0.22
		v=v*planet.radius+n*planet.relief*(h-crater*0.9)
	}
	return mesh
}

create_planets :: proc(world:^ecs.World,registry:^ecs.Component_Registry) {
	ecs.ensure_box3d_world(world)
	for planet,i in PLANETS {
		mesh:=build_mesh(planet)
		mesh.entity=ecs.create_entity(world)
		assert(ecs.add(world,registry,mesh.entity,ecs.Transform{position=planet.center,scale={1,1,1}}))
		vertices:=make([]b3.Vec3,len(mesh.vertices));defer delete(vertices)
		for v,j in mesh.vertices {vertices[j]={v[0],v[1],v[2]}}
		mesh.collision=b3.CreateMesh({vertices=raw_data(vertices),indices=raw_data(mesh.indices),
			vertexCount=i32(len(vertices)),triangleCount=i32(len(mesh.indices)/3),identifyEdges=true,useMedianSplit=true},nil,0)
		assert(mesh.collision!=nil,"planetoid collision mesh")
		mesh.body=ecs.create_box3d_body_id(world,{body_type="static"},{position=planet.center,scale={1,1,1}})
		shape:=b3.CreateMeshShape(mesh.body,ecs.create_box3d_shape_def(world,mesh.entity,0.8,0,0),mesh.collision,{1,1,1})
		mesh.shape=shape
		world.box3d_bodies[mesh.entity]=mesh.body
		world.physics_3d.shapes[b3.StoreShapeId(shape)]={mesh.entity,"Planetoid"}
		meshes[i]=mesh
	}
	for &entity,j in rocks {
		i:=j/3
		up:=unit(V3{math.sin(f32(j)*2.4)*0.8,1,math.cos(f32(j)*2.4)*0.8})
		entity=ecs.create_entity(world)
		assert(ecs.add(world,registry,entity,ecs.Transform{position=surface_point(world,i,up)+up*1.5,scale={1,1,1}}))
		assert(ecs.add(world,registry,entity,ecs.SphereCollider{radius=0.38,restitution=0.35,friction=0.7,rolling_resistance=0.15}))
		assert(ecs.add(world,registry,entity,ecs.RigidBody3D{body_type="dynamic",gravity_scale=0,linear_damping=0.1,angular_damping=0.2}))
	}
}
destroy_planets :: proc(world:^ecs.World) {
	for entity in rocks {if ecs.is_alive(world,entity) {ecs.destroy_entity(world,entity)}}
	rocks={}
	for &mesh in meshes {
		if !b3.IS_NULL(mesh.body) && b3.Body_IsValid(mesh.body) {
			ecs.destroy_entity(world,mesh.entity)
		}
		if mesh.collision!=nil {b3.DestroyMesh(mesh.collision)}
		delete(mesh.vertices);delete(mesh.indices);mesh={}
	}
}

// Closest nominal surface with a dead band prevents gravity flicker at a boundary.
gravity_source :: proc(position:V3,current:int)->int {
	best:=current
	score:=length(position-PLANETS[current].center)-PLANETS[current].radius
	for p,i in PLANETS {
		d:=length(position-p.center)-p.radius
		if d<score-0.8 {score=d;best=i}
	}
	return best
}
surface_point :: proc(world:^ecs.World,index:int,direction:V3)->V3 {
	p:=PLANETS[index];up:=unit(direction)
	origin:=p.center+up*(p.radius+4);delta:=-up*(p.radius+4)
	// Query this terrain only: rolling props must not move spawn/launch points.
	hit:=b3.Shape_RayCast(meshes[index].shape,{origin[0],origin[1],origin[2]},{delta[0],delta[1],delta[2]})
	if hit.hit {return V3{f32(hit.point.x),f32(hit.point.y),f32(hit.point.z)}+up*0.025}
	return p.center+up*p.radius
}
gate_direction :: proc(index:int)->V3 {return unit(PLANETS[(index+1)%len(PLANETS)].center-PLANETS[index].center)}

