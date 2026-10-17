package render

import "core:math"
import "core:testing"
import "rune:assets"
import "rune:ecs"
import "rune:geometry"
import rl "vendor:raylib"

@(test)
pick_3d_resolves_rendered_hierarchy_and_nearest_enabled_surface :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	parent:=ecs.create_entity(&w); ecs.add(&w,&r,parent,ecs.Transform{position={0,0,4},scale={2,1,1}})
	near:=ecs.create_entity(&w); ecs.set_parent(&w,near,parent)
	ecs.add(&w,&r,near,ecs.Transform{position={0,0,1},rotation={0,45,0},scale={1,2,1}})
	ecs.add(&w,&r,near,ecs.MeshRenderer{primitive="cube"})
	far:=ecs.create_entity(&w); ecs.add(&w,&r,far,ecs.Transform{position={0,0,9},scale={1,1,1}}); ecs.add(&w,&r,far,ecs.SphereRenderer{radius=0.5})
	hit,ok:=scene_pick_3d(&w,{},{0,0,20})
	testing.expect(t,ok && hit.entity==near && hit.distance>4 && hit.distance<5,"render-only child is picked using composed rotation and nonuniform scale")
	testing.expect(t,abs(rl.Vector3Length(hit.normal)-1)<0.001 && hit.normal[2]<0)
	ecs.set_enabled(&w,parent,false)
	hit,ok=scene_pick_3d(&w,{},{0,0,20}); testing.expect(t,ok && hit.entity==far && abs(hit.distance-8.5)<0.001,"disabled ancestors exclude their rendered children")
	_,ok=scene_pick_3d(&w,{},{0,0,8}); testing.expect(t,!ok,"translation bounds the query in world units")
}

@(test)
pick_3d_retains_flat_geometry_and_static_triangle_gaps :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	plane:=ecs.create_entity(&w); ecs.add(&w,&r,plane,ecs.Transform{position={0,3,0},scale={4,1,4}}); ecs.add(&w,&r,plane,ecs.MeshRenderer{primitive="plane"})
	hit,ok:=scene_pick_3d(&w,{0,6,0},{0,-8,0}); testing.expect(t,ok && hit.entity==plane && abs(hit.distance-3)<0.001)
	quad:=ecs.create_entity(&w); ecs.add(&w,&r,quad,ecs.Transform{position={4,0,5},scale={2,2,1}}); ecs.add(&w,&r,quad,ecs.MeshRenderer{primitive="quad"})
	hit,ok=scene_pick_3d(&w,{4,0,0},{0,0,10}); testing.expect(t,ok && hit.entity==quad && abs(hit.distance-5)<0.001)
	static:=ecs.create_entity(&w); ecs.add(&w,&r,static,ecs.Transform{position={0,0,5},scale={1,1,1}}); ecs.add(&w,&r,static,ecs.MeshRenderer{primitive="static"})
	mesh:geometry.Mesh; defer geometry.destroy_mesh(&mesh)
	append(&mesh.vertices,geometry.Vertex{position={-2,-2,0},normal={0,0,1}},geometry.Vertex{position={2,-2,0},normal={0,0,1}},geometry.Vertex{position={-2,2,0},normal={0,0,1}}); append(&mesh.indices,0,1,2)
	testing.expect(t,ecs.set_static_mesh(&w,static,mesh,collidable=false))
	hit,ok=scene_pick_3d(&w,{-1,-1,0},{0,0,10}); testing.expect(t,ok && hit.entity==static && abs(hit.distance-5)<0.001)
	_,ok=scene_pick_3d(&w,{1,1,0},{0,0,10}); testing.expect(t,!ok,"triangle gaps do not pick the enclosing bounds")
	for &v in mesh.vertices {v.position[2]+=3}
	testing.expect(t,ecs.set_static_mesh(&w,static,mesh,collidable=false))
	hit,ok=scene_pick_3d(&w,{-1,-1,0},{0,0,10}); testing.expect(t,ok && abs(hit.distance-8)<0.001,"CPU replacements are visible without a renderer upload")
}

@(test)
pick_3d_imported_bounds_are_read_only_and_follow_successful_cache_updates :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	manager:=assets.Asset_Manager{models=make(map[string]assets.Model_Asset)}; defer delete(manager.models)
	e:=ecs.create_entity(&w); ecs.add(&w,&r,e,ecs.Transform{position={0,0,5},scale={1,1,1}}); ecs.add(&w,&r,e,ecs.ModelRenderer{model="fixture.obj"})
	_,ok:=scene_pick_3d(&w,{},{0,0,10},&manager); testing.expect(t,!ok && len(manager.models)==0,"picking does not register or load missing models")
	manager.models["fixture.obj"]={revision=1}
	_,ok=scene_pick_3d(&w,{},{0,0,10},&manager); testing.expect(t,!ok,"a file watch alone does not invent model bounds")
	assets.cache_model_bounds(&manager,"fixture.obj",{{-2,-0.5,-0.2},{0.25,0.5,0.2}})
	hit:Scene_Ray_Hit_3D
	hit,ok=scene_pick_3d(&w,{-1,0,0},{0,0,10},&manager); testing.expect(t,ok && hit.entity==e && abs(hit.distance-4.8)<0.001,"asymmetric imported model uses its cached static local bounds")
	_,ok=scene_pick_3d(&w,{1,0,0},{0,0,10},&manager); testing.expect(t,!ok,"no unit-cube fallback outside the imported bounds")
	previous:=manager.models["fixture.obj"]; previous.revision+=1; manager.models["fixture.obj"]=previous
	hit,ok=scene_pick_3d(&w,{-1,0,0},{0,0,10},&manager); testing.expect(t,ok && abs(hit.distance-4.8)<0.001,"a failed or pending reload keeps bounds matching the retained visual model")
	assets.cache_model_bounds(&manager,"fixture.obj",{{-2,-0.5,1},{0.25,0.5,2}})
	hit,ok=scene_pick_3d(&w,{-1,0,0},{0,0,10},&manager); testing.expect(t,ok && abs(hit.distance-6)<0.001,"a successful renderer replacement publishes new geometry")
	assets.cache_model_bounds(&manager,"fixture.obj",{{1,0,0},{-1,1,1}})
	_,ok=scene_pick_3d(&w,{},{0,0,10},&manager); testing.expect(t,!ok,"malformed cached bounds are rejected")
}

@(test)
pick_3d_model_bounds_follow_rotated_nonuniform_hierarchy :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	manager:=assets.Asset_Manager{models=make(map[string]assets.Model_Asset)}; defer delete(manager.models)
	manager.models["fixture.obj"]={revision=1}
	assets.cache_model_bounds(&manager,"fixture.obj",{{-1,-0.25,-0.5},{1,0.75,0.5}})
	root:=ecs.create_entity(&w); ecs.add(&w,&r,root,ecs.Transform{position={10,0,0},rotation={0,90,0},scale={2,1,1}})
	child:=ecs.create_entity(&w); ecs.set_parent(&w,child,root)
	ecs.add(&w,&r,child,ecs.Transform{position={1,2,0},rotation={0,-45,0},scale={1,1,4}}); ecs.add(&w,&r,child,ecs.ModelRenderer{model="fixture.obj"})
	s:=f32(math.SQRT_TWO*0.5)
	front:=[3]f32{10-f32(math.SQRT_TWO),2.25,-2-f32(math.SQRT_TWO)}; normal:=[3]f32{-s,0,-s}
	hit,ok:=scene_pick_3d(&w,front+normal*3,-normal*10,&manager)
	testing.expect(t,ok && hit.entity==child && abs(hit.distance-3)<0.001 && rl.Vector3Length(hit.point-front)<0.001)
	testing.expect(t,rl.Vector3Length(hit.normal-normal)<0.001,"model surface and normal match composed rendered TRS")
}

@(test)
pick_3d_handles_inherited_identity_and_mirrored_scale :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	root:=ecs.create_entity(&w); ecs.add(&w,&r,root,ecs.Transform{position={0,0,5},scale={-2,1,1}})
	e:=ecs.create_entity(&w); ecs.set_parent(&w,e,root); ecs.add(&w,&r,e,ecs.MeshRenderer{primitive="cube"})
	hit,ok:=scene_pick_3d(&w,{},{0,0,10})
	testing.expect(t,ok && hit.entity==e && abs(hit.distance-4.5)<0.001,"a renderer without its own Transform inherits the parent's pose")
	testing.expect(t,rl.Vector3Length(hit.normal-([3]f32{0,0,-1}))<0.001,"mirrored scale preserves a ray-facing unit normal")
	ecs.set_transform(&w,root,ecs.Transform{position={0,0,5},scale={0,1,1}})
	_,ok=scene_pick_3d(&w,{},{0,0,10}); testing.expect(t,!ok,"a singular rendered transform cannot be inverted")
}

@(test)
pick_3d_rejects_nonfinite_and_empty_queries :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	e:=ecs.create_entity(&w); ecs.add(&w,&r,e,ecs.Transform{position={0,0,5},scale={1,1,1}}); ecs.add(&w,&r,e,ecs.MeshRenderer{primitive="cube"})
	nan:=transmute(f32)u32(0x7fc00000); infinity:=transmute(f32)u32(0x7f800000)
	_,ok:=scene_pick_3d(nil,{},{0,0,10}); testing.expect(t,!ok)
	_,ok=scene_pick_3d(&w,{},{}); testing.expect(t,!ok)
	_,ok=scene_pick_3d(&w,{nan,0,0},{0,0,10}); testing.expect(t,!ok)
	_,ok=scene_pick_3d(&w,{},{0,0,infinity}); testing.expect(t,!ok)
}
