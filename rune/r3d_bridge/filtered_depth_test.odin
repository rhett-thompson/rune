package r3d_bridge

import "core:math"
import "core:testing"
import "rune:assets"
import "rune:ecs"
import "rune:geometry"
import r3d "r3d:r3d"
import rl "vendor:raylib"

@(test)
depth_pass_filter_excludes_only_requested_entities_and_descendants :: proc(t:^testing.T) {
	w:=ecs.init();defer ecs.destroy(&w)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	root:=ecs.create_entity(&w)
	assert(ecs.add(&w,&r,root,ecs.default_transform()))
	gap:=ecs.create_entity(&w);assert(ecs.set_parent(&w,gap,root))
	child:=ecs.create_entity(&w);assert(ecs.set_parent(&w,child,gap))
	assert(ecs.add(&w,&r,child,ecs.default_transform()))
	assert(ecs.add(&w,&r,child,ecs.MeshRenderer{primitive="cube",material="shared.material.json"}))
	sibling:=ecs.create_entity(&w)
	assert(ecs.add(&w,&r,sibling,ecs.default_transform()))
	assert(ecs.add(&w,&r,sibling,ecs.MeshRenderer{primitive="cube",material="shared.material.json"}))
	ignored:=[1]ecs.Entity{root}
	filter:=Depth_Pass_Filter{ignored_subtrees=ignored[:]}
	testing.expect(t,depth_pass_excludes(&w,root,filter) && depth_pass_excludes(&w,gap,filter) && depth_pass_excludes(&w,child,filter),"A requested subtree includes its root and descendants across transform-free groups")
	testing.expect(t,!depth_pass_excludes(&w,sibling,filter),"Another renderer sharing the same material stays included")
	testing.expect(t,depth_pass_filter_effective(&w,filter),"A non-rendering group is effective when it contains a visible renderer")
	testing.expect(t,!depth_pass_excludes(&w,child,{}),"An absent filter preserves the existing depth policy")
	ignored[0]=child
	testing.expect(t,!depth_pass_excludes(&w,root,filter) && !depth_pass_excludes(&w,gap,filter) && depth_pass_excludes(&w,child,filter),"Excluding one leaf never excludes its ancestors")
	material,_:=ecs.get_mesh_renderer(&w,child)
	testing.expect(t,material.material=="shared.material.json" && ecs.is_enabled(&w,child),"Depth selection does not mutate material assignment or entity activation")
}

@(test)
depth_pass_filter_ignores_empty_stale_disabled_and_nonrendering_subtrees :: proc(t:^testing.T) {
	w:=ecs.init();defer ecs.destroy(&w)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	testing.expect(t,!depth_pass_filter_effective(&w,{}))
	group:=ecs.create_entity(&w)
	assert(ecs.add(&w,&r,group,ecs.default_transform()))
	ignored:=[3]ecs.Entity{0,group,0}
	filter:=Depth_Pass_Filter{ignored_subtrees=ignored[:]}
	testing.expect(t,!depth_pass_filter_effective(&w,filter),"A transform-only subtree does not require a second depth pass")
	child:=ecs.create_entity(&w);assert(ecs.set_parent(&w,child,group))
	assert(ecs.add(&w,&r,child,ecs.default_transform()))
	assert(ecs.add(&w,&r,child,ecs.MeshRenderer{primitive="cube"}))
	testing.expect(t,depth_pass_filter_effective(&w,filter))
	assert(ecs.set_enabled(&w,group,false))
	testing.expect(t,!depth_pass_filter_effective(&w,filter),"Disabled ancestors make excluded geometry irrelevant")
	assert(ecs.set_enabled(&w,group,true))
	assert(ecs.set_enabled(&w,child,false))
	testing.expect(t,!depth_pass_filter_effective(&w,filter),"A locally disabled renderer also needs no extra pass")
	assert(ecs.set_enabled(&w,child,true))
	testing.expect(t,depth_pass_filter_effective(&w,filter))
	assert(ecs.destroy_entity(&w,group))
	testing.expect(t,!depth_pass_filter_effective(&w,filter),"Destroyed roots cannot leave a stale pass request")
	replacement:=ecs.create_entity(&w)
	assert(ecs.add(&w,&r,replacement,ecs.default_transform()))
	assert(ecs.add(&w,&r,replacement,ecs.MeshRenderer{primitive="cube"}))
	testing.expect(t,!depth_pass_excludes(&w,replacement,filter) && !depth_pass_filter_effective(&w,filter),"Reused entity slots do not inherit an old handle's exclusion")
}

@(test)
depth_pass_render_rejects_uninitialized_context_and_zero_view_teardown_is_safe :: proc(t:^testing.T) {
	w:=ecs.init();defer ecs.destroy(&w)
	r:=ecs.init_registry();defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	entity:=ecs.create_entity(&w)
	assert(ecs.add(&w,&r,entity,ecs.default_transform()))
	assert(ecs.add(&w,&r,entity,ecs.MeshRenderer{primitive="cube"}))
	ignored:=[1]ecs.Entity{entity}
	filter:=Depth_Pass_Filter{ignored_subtrees=ignored[:]}
	view:Depth_Pass3D
	ctx:Context
	camera:=rl.Camera3D{position={0,0,5},target={},up={0,1,0},fovy=60,projection=.PERSPECTIVE}
	entity_count:=w.entity_count
	ctx.initialized=true
	testing.expect(t,!render_scene_depth(&view,&ctx,&w,nil,camera,{},0),"An empty filter short-circuits before accessing the GPU even with an initialized bridge")
	testing.expect(t,view.target.id==0 && view.target.texture.id==0 && !view.valid,"The default path allocates no depth target")
	ctx.initialized=false
	testing.expect(t,!render_scene_depth(&view,&ctx,&w,nil,camera,filter,0),"A real exclusion still cannot render through an uninitialized bridge")
	testing.expect(t,view.target.id==0 && view.target.texture.id==0 && !view.valid)
	testing.expect(t,w.entity_count==entity_count && ecs.is_enabled(&w,entity),"Rejected passes leave the live scene untouched")
	destroy_depth_pass_3d(&view)
	destroy_depth_pass_3d(&view)
}

@(test)
depth_pass_only_skips_proven_offscreen_exclusions :: proc(t: ^testing.T) {
	w := ecs.init(); defer ecs.destroy(&w)
	r := ecs.init_registry(); defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	ctx := new(Context); defer free(ctx)
	ctx.static_mesh_generation = w.generation
	ctx.static_meshes = make(map[ecs.Entity]Static_Mesh_Cache); defer delete(ctx.static_meshes)
	ctx.r3d_materials = make(map[string]R3D_Material_Asset); defer delete(ctx.r3d_materials)
	manager := assets.Asset_Manager {
		materials = make(map[string]assets.Material_Asset),
		material_previews = make(map[string]assets.Material_Data),
	}
	defer {delete(manager.materials); delete(manager.material_previews)}
	material :: "beam.material.json"
	manager.materials[material] = {data = {billboard = "disabled"}}

	root := ecs.create_entity(&w)
	assert(ecs.add(&w, &r, root, ecs.Transform{position={20, 0, -4}, scale={1, 1, 1}}))
	beam := ecs.create_entity(&w)
	assert(ecs.set_parent(&w, beam, root))
	assert(ecs.add(&w, &r, beam, ecs.default_transform()))
	assert(ecs.add(&w, &r, beam, ecs.MeshRenderer{primitive="static", material=material}))
	cells := [1]u8{1}
	palette := [2][4]u8{{}, {255, 255, 255, 255}}
	mesh, generated := geometry.surface({size={1, 1, 1}, cells=cells[:], origin={-0.5, -0.5, -0.5}, spacing=1}, palette[:])
	assert(generated); defer geometry.destroy_mesh(&mesh)
	assert(ecs.set_static_mesh_owned(&w, beam, &mesh, collidable=false))
	ctx.static_meshes[beam] = {revision=w.static_meshes[beam].revision, mesh={aabb={{-0.5, -0.5, -0.5}, {0.5, 0.5, 0.5}}}}
	roots := [1]ecs.Entity{root}
	filter := Depth_Pass_Filter{ignored_subtrees=roots[:]}
	frustum := r3d.ComputeFrustum(rl.MatrixPerspective(60*math.PI/180, 1, 0.1, 100))
	testing.expect(t, depth_pass_filter_effective(&w, filter), "Standalone depth still recognizes offscreen exclusions")
	testing.expect(t, depth_pass_exclusions_outside_frustum(ctx, &w, &manager, filter, &frustum))
	testing.expect(t, !depth_pass_exclusions_outside_frustum(ctx, &w, nil, filter, &frustum), "Unknown materials fail open")
	testing.expect(t, !depth_pass_exclusions_outside_frustum(ctx, &w, &manager, filter, nil), "Unknown projections fail open")

	manager.material_previews[material] = {surface_shader="move-vertices.glsl"}
	testing.expect(t, !depth_pass_exclusions_outside_frustum(ctx, &w, &manager, filter, &frustum), "Preview shaders may move geometry into view")
	delete_key(&manager.material_previews, material)
	shader: r3d.SurfaceShader
	ctx.r3d_materials[material] = {material={shader=&shader}}
	testing.expect(t, !depth_pass_exclusions_outside_frustum(ctx, &w, &manager, filter, &frustum), "A retained shader after reload also prevents skipping")
	ctx.r3d_materials[material] = {material={billboardMode=.FRONT}}
	testing.expect(t, !depth_pass_exclusions_outside_frustum(ctx, &w, &manager, filter, &frustum), "A billboard can extend past its authored bounds")
	delete_key(&ctx.r3d_materials, material)
	assert(ecs.add(&w, &r, beam, ecs.SphereRenderer{radius=1}))
	testing.expect(t, !depth_pass_exclusions_outside_frustum(ctx, &w, &manager, filter, &frustum), "The static mesh bounds cannot prove anything about a compound renderer")
	assert(ecs.remove_component(&w, beam, "SphereRenderer"))

	assert(ecs.set_transform(&w, root, ecs.Transform{position={0, 0, -0.2}, scale={1, 1, 1}}))
	testing.expect(t, !depth_pass_exclusions_outside_frustum(ctx, &w, &manager, filter, &frustum), "A box crossing the near plane still needs filtered depth")
	assert(ecs.set_transform(&w, root, ecs.Transform{position={2.5, 0, -4}, scale={1, 1, 1}}))
	testing.expect(t, !depth_pass_exclusions_outside_frustum(ctx, &w, &manager, filter, &frustum), "A side-plane crossing must stay eligible after a live ancestor edit")
	assert(ecs.set_transform(&w, root, ecs.Transform{position={20, 0, -4}, scale={1, 1, 1}}))
	cache := ctx.static_meshes[beam]
	cache.revision += 1
	ctx.static_meshes[beam] = cache
	testing.expect(t, !depth_pass_exclusions_outside_frustum(ctx, &w, &manager, filter, &frustum), "Stale uploaded geometry fails open")
}

@(test)
filtered_depth_rejects_only_proven_offscreen_stock_props :: proc(t: ^testing.T) {
	w := ecs.init(); defer ecs.destroy(&w)
	r := ecs.init_registry(); defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	ctx := new(Context); defer free(ctx)
	defer release_render_cache(ctx)
	ctx.cube_no_shadow = {vertexCount=24, aabb={{-0.5, -0.5, -0.5}, {0.5, 0.5, 0.5}}}
	ctx.r3d_materials = make(map[string]R3D_Material_Asset); defer delete(ctx.r3d_materials)
	manager := assets.Asset_Manager{materials=make(map[string]assets.Material_Asset)}
	defer delete(manager.materials)
	material :: "stock.material.json"
	manager.materials[material] = {data={billboard="disabled"}}

	root := ecs.create_entity(&w)
	assert(ecs.add(&w, &r, root, ecs.Transform{position={20, 0, -4}, scale={1, 1, 1}}))
	prop := ecs.create_entity(&w)
	assert(ecs.set_parent(&w, prop, root))
	assert(ecs.add(&w, &r, prop, ecs.default_transform()))
	assert(ecs.add(&w, &r, prop, ecs.MeshRenderer{primitive="cube", material=material}))
	frustum := r3d.ComputeFrustum(rl.MatrixPerspective(60*math.PI/180, 1, 0.1, 100))
	prepare_render_cache(ctx, &w)
	entry := ctx.render_cache.entries[prop]
	testing.expect(t, depth_stock_prop_outside_frustum(ctx, &w, &manager, prop, &entry, .Non_Plane, &frustum))
	testing.expect(t, !depth_stock_prop_outside_frustum(ctx, &w, &manager, prop, &entry, .Plane_Only, &frustum), "Each rejection belongs to a stock prop's own pass")
	testing.expect(t, !depth_stock_prop_outside_frustum(ctx, &w, nil, prop, &entry, .Non_Plane, &frustum), "Unknown materials retain their submissions")
	assert(ecs.add(&w, &r, prop, ecs.SphereRenderer{radius=1}))
	testing.expect(t, !depth_stock_prop_outside_frustum(ctx, &w, &manager, prop, &entry, .Non_Plane, &frustum), "A cube's bounds do not cover its sphere renderer")
	assert(ecs.remove_component(&w, prop, "SphereRenderer"))

	manager.materials[material] = {data={surface_shader="deformed.glsl"}}
	testing.expect(t, !depth_stock_prop_outside_frustum(ctx, &w, &manager, prop, &entry, .Non_Plane, &frustum), "An authored shader can move vertices into view")
	manager.materials[material] = {data={billboard="disabled"}}
	ctx.r3d_materials[material] = {material={billboardMode=.FRONT}}
	testing.expect(t, !depth_stock_prop_outside_frustum(ctx, &w, &manager, prop, &entry, .Non_Plane, &frustum), "A retained billboard can extend past its authored bounds")
	delete_key(&ctx.r3d_materials, material)

	// A long rotated box crosses the side plane even when its center is outside.
	assert(ecs.set_transform(&w, root, ecs.Transform{position={4, 0, -4}, rotation={0, 40, 0}, scale={8, 1, 1}}))
	prepare_render_cache(ctx, &w)
	entry = ctx.render_cache.entries[prop]
	testing.expect(t, !depth_stock_prop_outside_frustum(ctx, &w, &manager, prop, &entry, .Non_Plane, &frustum), "The live composed bounds retain a rotated prop that crosses into view")
}
