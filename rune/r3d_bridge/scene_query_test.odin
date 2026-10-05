package r3d_bridge

import "core:testing"
import "rune:ecs"
import "rune:geometry"

@(test)
scene_query_picks_render_only_primitives_with_hierarchy_and_occlusion :: proc(t: ^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	parent:=ecs.create_entity(&w); ecs.add(&w,&r,parent,ecs.Transform{position={0,0,4},scale={2,1,1}})
	near:=ecs.create_entity(&w); ecs.set_parent(&w,near,parent)
	ecs.add(&w,&r,near,ecs.Transform{position={0,0,1},rotation={0,45,0},scale={1,2,1}})
	ecs.add(&w,&r,near,ecs.MeshRenderer{primitive="cube"})
	far:=ecs.create_entity(&w); ecs.add(&w,&r,far,ecs.Transform{position={0,0,9},scale={1,1,1}}); ecs.add(&w,&r,far,ecs.MeshRenderer{primitive="cube"})
	hit,ok:=scene_raycast(&w,{},{0,0,20})
	testing.expect(t,ok && hit.entity==near && hit.distance>4 && hit.distance<5,"rotated/scaled child uses rendered hierarchy without needing a collider")
	hit,ok=scene_raycast(&w,{},{0,0,20},near); testing.expect(t,ok && hit.entity==far,"ignore applies to the exact rendered entity")
	ecs.set_enabled(&w,parent,false)
	hit,ok=scene_raycast(&w,{},{0,0,20}); testing.expect(t,ok && hit.entity==far,"disabled ancestors hide children")
	_,ok=scene_raycast(&w,{},{0,0,8}); testing.expect(t,!ok,"ray is a bounded segment")
	_,ok=scene_raycast(&w,{},{}); testing.expect(t,!ok)
}

@(test)
scene_query_static_paint_respects_triangle_gaps_and_mesh_replacement :: proc(t: ^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	e:=ecs.create_entity(&w); ecs.add(&w,&r,e,ecs.Transform{position={0,0,5},scale={1,1,1}}); ecs.add(&w,&r,e,ecs.MeshRenderer{primitive="static"})
	mesh:geometry.Mesh; defer geometry.destroy_mesh(&mesh)
	append(&mesh.vertices,geometry.Vertex{position={-2,-2,0},normal={0,0,1}},geometry.Vertex{position={2,-2,0},normal={0,0,1}},geometry.Vertex{position={-2,2,0},normal={0,0,1}})
	append(&mesh.indices,0,1,2)
	testing.expect(t,ecs.set_static_mesh(&w,e,mesh,collidable=false))
	hit,ok:=scene_raycast(&w,{-1,-1,0},{0,0,10}); testing.expect(t,ok && hit.entity==e && abs(hit.distance-5)<0.001,"paint needs no native collision")
	_,ok=scene_raycast(&w,{1,1,0},{0,0,10}); testing.expect(t,!ok,"empty triangle space remains unpickable")
	hit,ok=scene_raycast(&w,{-1,-1,10},{0,0,-10}); testing.expect(t,ok && hit.entity==e,"both sides can be inspected during free flight")
	for &v in mesh.vertices {v.position[2]+=3}
	testing.expect(t,ecs.set_static_mesh(&w,e,mesh,collidable=false))
	hit,ok=scene_raycast(&w,{-1,-1,0},{0,0,10}); testing.expect(t,ok && abs(hit.distance-8)<0.001,"queries use replacement CPU geometry")
	ecs.destroy_entity(&w,e)
	_,ok=scene_raycast(&w,{-1,-1,0},{0,0,10}); testing.expect(t,!ok,"deleted geometry cannot leave a stale hit")
}
