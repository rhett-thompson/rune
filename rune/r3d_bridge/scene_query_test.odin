package r3d_bridge

import "core:testing"
import "core:math"
import "rune:ecs"
import "rune:geometry"
import rl "vendor:raylib"

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
scene_query_ignores_multiple_roots_and_attached_descendants :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	assembly:=ecs.create_entity(&w)
	near:=ecs.create_entity(&w); ecs.set_parent(&w,near,assembly)
	ecs.add(&w,&r,near,ecs.Transform{position={0,0,2},scale={1,1,1}}); ecs.add(&w,&r,near,ecs.MeshRenderer{primitive="cube"})
	trim:=ecs.create_entity(&w); ecs.set_parent(&w,trim,near)
	ecs.add(&w,&r,trim,ecs.Transform{position={0,0,2},scale={1,1,1}}); ecs.add(&w,&r,trim,ecs.MeshRenderer{primitive="cube"})
	sibling:=ecs.create_entity(&w); ecs.set_parent(&w,sibling,assembly)
	ecs.add(&w,&r,sibling,ecs.Transform{position={0,0,6},scale={1,1,1}}); ecs.add(&w,&r,sibling,ecs.MeshRenderer{primitive="cube"})
	far:=ecs.create_entity(&w); ecs.set_parent(&w,far,assembly)
	ecs.add(&w,&r,far,ecs.Transform{position={0,0,8},scale={1,1,1}}); ecs.add(&w,&r,far,ecs.MeshRenderer{primitive="cube"})
	hit,ok:=scene_raycast(&w,{},{0,0,20},near)
	testing.expect(t,ok && hit.entity==trim,"legacy ignore still excludes only the exact entity")
	roots:=[2]ecs.Entity{0,near}
	hit,ok=scene_raycast(&w,{},{0,0,20},ignored_subtrees=roots[:])
	testing.expect(t,ok && hit.entity==sibling,"a root excludes attached descendants without hiding sibling parts")
	roots={near,sibling}
	hit,ok=scene_raycast(&w,{},{0,0,20},ignored_subtrees=roots[:])
	testing.expect(t,ok && hit.entity==far,"multiple assembly roots leave unrelated siblings available as targets")
}

@(test)
scene_query_normal_is_unit_world_space_and_faces_the_ray :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	e:=ecs.create_entity(&w)
	ecs.add(&w,&r,e,ecs.Transform{position={0,0,5},scale={2,1,0.5}}); ecs.add(&w,&r,e,ecs.MeshRenderer{primitive="static"})
	mesh:geometry.Mesh; defer geometry.destroy_mesh(&mesh)
	append(&mesh.vertices,geometry.Vertex{position={-1,-1,-1},normal={0,0,1}},geometry.Vertex{position={1,-1,1},normal={0,0,1}},geometry.Vertex{position={0,1,0},normal={0,0,1}})
	append(&mesh.indices,0,1,2)
	testing.expect(t,ecs.set_static_mesh(&w,e,mesh,collidable=false))
	hit,ok:=scene_raycast(&w,{},{0,0,10})
	testing.expect(t,ok && abs(hit.distance-5)<0.001)
	testing.expect(t,abs(rl.Vector3Length(hit.normal)-1)<0.001 && hit.normal[2]<0,"front-side normal points toward the ray origin")
	testing.expect(t,abs(rl.Vector3DotProduct(hit.normal,{4,0,1}))<0.001 && abs(rl.Vector3DotProduct(hit.normal,{2,2,0.5}))<0.001,"inverse-transpose keeps the normal perpendicular to both scaled triangle edges")
	back,back_ok:=scene_raycast(&w,{0,0,10},{0,0,-10})
	testing.expect(t,back_ok && rl.Vector3Length(back.normal+hit.normal)<0.001,"two-sided placement flips the normal for a back-side ray")
	cube:=ecs.create_entity(&w)
	ecs.add(&w,&r,cube,ecs.Transform{position={5,0,5},rotation={0,45,0},scale={2,1,1}}); ecs.add(&w,&r,cube,ecs.MeshRenderer{primitive="cube"})
	cube_hit,cube_ok:=scene_raycast(&w,{5.1,0,0},{0,0,10})
	testing.expect(t,cube_ok && cube_hit.entity==cube && abs(rl.Vector3Length(cube_hit.normal)-1)<0.001 && abs(abs(cube_hit.normal[0])-f32(math.SQRT_TWO*0.5))<0.001 && cube_hit.normal[2]<0,"primitive normals follow world rotation")
}

@(test)
scene_projected_bounds_resolves_rotated_hierarchy_and_enabled_children :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	root:=ecs.create_entity(&w); ecs.add(&w,&r,root,ecs.Transform{position={10,0,0},rotation={0,90,0},scale={2,1,1}})
	child:=ecs.create_entity(&w); ecs.set_parent(&w,child,root)
	ecs.add(&w,&r,child,ecs.Transform{position={1,2,0},rotation={0,-45,0},scale={1,1,4}}); ecs.add(&w,&r,child,ecs.MeshRenderer{primitive="cube"})
	low,high,ok:=scene_projected_bounds(&w,root,{10,0,0},{7,0,0})
	extent:=f32(1.5*math.SQRT_TWO)
	testing.expect(t,ok && abs(low+extent)<0.001 && abs(high-extent)<0.001,"direction is normalized and rotated nonuniform boxes use oriented support rather than an axis-aligned approximation")
	low,high,ok=scene_projected_bounds(&w,root,{0,1,0},{0,1,0})
	testing.expect(t,ok && abs(low-0.5)<0.001 && abs(high-1.5)<0.001,"projection distances are relative to caller origin")
	ecs.set_enabled(&w,child,false)
	_,_,ok=scene_projected_bounds(&w,root,{},{1,0,0}); testing.expect(t,!ok,"disabled descendants do not contribute support")
	low,high,ok=scene_projected_bounds(&w,root,{10,0,0},{1,0,0},include_disabled=true)
	testing.expect(t,ok && abs(low+extent)<0.001 && abs(high-extent)<0.001,"authoring tools can explicitly measure a disabled descendant's source geometry")
	ecs.set_enabled(&w,child,true); ecs.set_enabled(&w,root,false)
	_,_,ok=scene_projected_bounds(&w,root,{},{1,0,0}); testing.expect(t,!ok,"disabled ancestors hide the full rendered subtree")
	low,high,ok=scene_projected_bounds(&w,root,{10,0,0},{1,0,0},include_disabled=true)
	testing.expect(t,ok && abs(low+extent)<0.001 && abs(high-extent)<0.001,"the opt-in also includes geometry under disabled ancestors")
}

@(test)
scene_projected_bounds_preserves_flat_primitives_and_cpu_mesh_geometry :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	plane:=ecs.create_entity(&w)
	ecs.add(&w,&r,plane,ecs.Transform{position={0,3,0},scale={4,2,6}}); ecs.add(&w,&r,plane,ecs.MeshRenderer{primitive="plane"})
	low,high,ok:=scene_projected_bounds(&w,plane,{},{0,1,0})
	testing.expect(t,ok && abs(low-3)<0.001 && abs(high-3)<0.001,"planes retain zero thickness without broad-phase padding")
	quad:=ecs.create_entity(&w)
	ecs.add(&w,&r,quad,ecs.Transform{position={0,0,7},rotation={0,90,0},scale={4,2,1}}); ecs.add(&w,&r,quad,ecs.MeshRenderer{primitive="quad"})
	low,high,ok=scene_projected_bounds(&w,quad,{1,0,0},{1,0,0})
	testing.expect(t,ok && abs(low+1)<0.001 && abs(high+1)<0.001,"quad support uses the rotated local plane")
	static:=ecs.create_entity(&w)
	ecs.add(&w,&r,static,ecs.Transform{position={3,0,0},scale={2,1,1}}); ecs.add(&w,&r,static,ecs.MeshRenderer{primitive="static"})
	mesh:geometry.Mesh; defer geometry.destroy_mesh(&mesh)
	append(&mesh.vertices,geometry.Vertex{position={0,0,0},normal={0,0,1}},geometry.Vertex{position={2,0,0},normal={0,0,1}},geometry.Vertex{position={0,2,0},normal={0,0,1}}); append(&mesh.indices,0,1,2)
	testing.expect(t,ecs.set_static_mesh(&w,static,mesh,collidable=false))
	low,high,ok=scene_projected_bounds(&w,static,{3,0,0},{1,1,0})
	testing.expect(t,ok && abs(low)<0.001 && abs(high-f32(2*math.SQRT_TWO))<0.001,"static support follows actual vertices, not empty corners of their AABB")
	for &vertex in mesh.vertices {vertex.position[0]+=1}
	testing.expect(t,ecs.set_static_mesh(&w,static,mesh,collidable=false))
	low,high,ok=scene_projected_bounds(&w,static,{3,0,0},{1,1,0})
	testing.expect(t,ok && abs(low-f32(math.SQRT_TWO))<0.001 && abs(high-f32(3*math.SQRT_TWO))<0.001,"CPU mesh replacements update support immediately")
}

@(test)
scene_projected_bounds_uses_exact_rotated_ellipsoid_support :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	e:=ecs.create_entity(&w)
	ecs.add(&w,&r,e,ecs.Transform{position={5,0,0},rotation={0,45,0},scale={2,1,4}}); ecs.add(&w,&r,e,ecs.SphereRenderer{radius=0.5})
	low,high,ok:=scene_projected_bounds(&w,e,{3,0,0},{1,0,0})
	extent:=f32(math.sqrt(2.5))
	testing.expect(t,ok && abs(low-(2-extent))<0.001 && abs(high-(2+extent))<0.001,"rotated ellipsoid support is smaller than its enclosing box")
}

@(test)
scene_queries_reject_invalid_inputs_and_unsupported_subtrees :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	e:=ecs.create_entity(&w); ecs.add(&w,&r,e,ecs.Transform{scale={1,1,1}}); ecs.add(&w,&r,e,ecs.MeshRenderer{primitive="cylinder"})
	infinity:=transmute(f32)u32(0x7f800000)
	not_a_number:=transmute(f32)u32(0x7fc00000)
	_,_,ok:=scene_projected_bounds(&w,e,{},{1,0,0}); testing.expect(t,!ok,"unsupported primitives do not invent a footprint")
	_,_,ok=scene_projected_bounds(nil,e,{},{1,0,0}); testing.expect(t,!ok)
	_,_,ok=scene_projected_bounds(&w,0,{},{1,0,0}); testing.expect(t,!ok)
	_,_,ok=scene_projected_bounds(&w,ecs.Entity(999),{},{1,0,0}); testing.expect(t,!ok)
	_,_,ok=scene_projected_bounds(&w,e,{},{}); testing.expect(t,!ok)
	_,_,ok=scene_projected_bounds(&w,e,{infinity,0,0},{1,0,0}); testing.expect(t,!ok)
	_,_,ok=scene_projected_bounds(&w,e,{},{not_a_number,0,0}); testing.expect(t,!ok)
	_,ray_ok:=scene_raycast(nil,{},{0,0,1}); testing.expect(t,!ray_ok)
	_,ray_ok=scene_raycast(&w,{not_a_number,0,0},{0,0,1}); testing.expect(t,!ray_ok)
	_,ray_ok=scene_raycast(&w,{},{0,0,infinity}); testing.expect(t,!ray_ok)
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
