package render

import "core:testing"
import "rune:assets"
import "rune:ecs"
import "rune:geometry"
import rl "vendor:raylib"

@(private)
selection_rect_close_3d :: proc(a,b:rl.Rectangle) -> bool {
	return abs(a.x-b.x)<0.002 && abs(a.y-b.y)<0.002 && abs(a.width-b.width)<0.002 && abs(a.height-b.height)<0.002
}

@(test)
selection_3d_projects_primitives_in_both_camera_modes :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	e:=ecs.create_entity(&w); ecs.add(&w,&r,e,ecs.Transform{scale={1,1,1}}); ecs.add(&w,&r,e,ecs.MeshRenderer{primitive="cube"})
	camera:=rl.Camera3D{position={0,0,10},target={},up={0,1,0},fovy=6,projection=.ORTHOGRAPHIC}
	bounds,ok:=scene_selection_bounds_3d(&w,nil,e,camera,{800,600},0.1,100)
	testing.expect(t,ok && selection_rect_close_3d(bounds,{350,250,100,100}),"orthographic cube has its current screen bounds")
	camera.projection=.PERSPECTIVE; camera.fovy=90
	bounds,ok=scene_selection_bounds_3d(&w,nil,e,camera,{800,600},0.1,100)
	extent:=f32(150)/9.5
	testing.expect(t,ok && selection_rect_close_3d(bounds,{400-extent,300-extent,extent*2,extent*2}),"perspective bound uses the nearest projected box corners")
	ecs.set_mesh_renderer(&w,e,ecs.MeshRenderer{primitive="quad"})
	bounds,ok=scene_selection_bounds_3d(&w,nil,e,camera,{800,600},0.1,100)
	testing.expect(t,ok && selection_rect_close_3d(bounds,{385,285,30,30}),"flat quad retains its zero-depth geometry")
	ecs.set_mesh_renderer(&w,e,ecs.MeshRenderer{primitive="plane"})
	camera.position={0,10,0}; camera.up={0,0,-1}; camera.projection=.ORTHOGRAPHIC; camera.fovy=6
	bounds,ok=scene_selection_bounds_3d(&w,nil,e,camera,{800,600},0.1,100)
	testing.expect(t,ok && selection_rect_close_3d(bounds,{350,250,100,100}),"plane bounds use its XZ surface")
}

@(test)
selection_3d_clips_camera_slab_and_viewport :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	e:=ecs.create_entity(&w); ecs.add(&w,&r,e,ecs.Transform{position={0,0,-1},scale={2,2,2}}); ecs.add(&w,&r,e,ecs.MeshRenderer{primitive="cube"})
	camera:=rl.Camera3D{target={0,0,-1},up={0,1,0},fovy=90,projection=.PERSPECTIVE}
	bounds,ok:=scene_selection_bounds_3d(&w,nil,e,camera,{200,200},1,10)
	testing.expect(t,ok && selection_rect_close_3d(bounds,{0,0,200,200}),"near-plane intersections remain finite when the box reaches the camera")
	ecs.set_transform(&w,e,ecs.Transform{position={0,0,2},scale={2,2,2}})
	_,ok=scene_selection_bounds_3d(&w,nil,e,camera,{200,200},1,10); testing.expect(t,!ok,"behind-camera boxes do not flip onto the display")
	ecs.set_transform(&w,e,ecs.Transform{position={0,0,-12},scale={2,2,2}})
	_,ok=scene_selection_bounds_3d(&w,nil,e,camera,{200,200},1,10); testing.expect(t,!ok,"boxes beyond the far plane have no overlay")
	ecs.set_transform(&w,e,ecs.Transform{position={0,0,-10},scale={2,2,2}})
	bounds,ok=scene_selection_bounds_3d(&w,nil,e,camera,{200,200},1,10)
	extent:=f32(100)/9
	testing.expect(t,ok && selection_rect_close_3d(bounds,{100-extent,100-extent,extent*2,extent*2}),"far-plane crossing keeps the visible front portion")
	ecs.set_transform(&w,e,ecs.Transform{position={10,0,-10},scale={2,2,2}})
	bounds,ok=scene_selection_bounds_3d(&w,nil,e,camera,{200,200},1,20)
	testing.expect(t,ok && bounds.x>181 && bounds.x<182 && bounds.x+bounds.width==200,"partial viewport bounds are clipped at the screen edge")
	ecs.set_transform(&w,e,ecs.Transform{position={20,0,-10},scale={2,2,2}})
	_,ok=scene_selection_bounds_3d(&w,nil,e,camera,{200,200},1,20); testing.expect(t,!ok,"fully offscreen geometry is rejected")
}

@(test)
selection_3d_follows_inherited_mirrored_rotated_pose_and_activation :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	parent:=ecs.create_entity(&w); ecs.add(&w,&r,parent,ecs.Transform{position={1,0,0},rotation={0,0,90},scale={-2,1,1}})
	e:=ecs.create_entity(&w); ecs.set_parent(&w,e,parent); ecs.add(&w,&r,e,ecs.MeshRenderer{primitive="cube"})
	camera:=rl.Camera3D{position={0,0,10},target={},up={0,1,0},fovy=6,projection=.ORTHOGRAPHIC}
	bounds,ok:=scene_selection_bounds_3d(&w,nil,e,camera,{800,600},0.1,100)
	testing.expect(t,ok && selection_rect_close_3d(bounds,{450,200,100,200}),"renderer without a local Transform inherits mirrored composed TRS")
	ecs.set_enabled(&w,parent,false)
	_,ok=scene_selection_bounds_3d(&w,nil,e,camera,{800,600},0.1,100); testing.expect(t,!ok,"disabled ancestor hides the selection")
	ecs.set_enabled(&w,parent,true)
	ecs.set_transform(&w,parent,ecs.Transform{scale={0,1,1}})
	_,ok=scene_selection_bounds_3d(&w,nil,e,camera,{800,600},0.1,100); testing.expect(t,!ok,"singular geometry does not create a highlight")
}

@(test)
selection_3d_uses_cpu_mesh_replacements_and_read_only_model_cache :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	manager:=assets.Asset_Manager{models=make(map[string]assets.Model_Asset)}; defer delete(manager.models)
	camera:=rl.Camera3D{target={0,0,-1},up={0,1,0},fovy=10,projection=.ORTHOGRAPHIC}
	e:=ecs.create_entity(&w); ecs.add(&w,&r,e,ecs.Transform{scale={1,1,1}}); ecs.add(&w,&r,e,ecs.MeshRenderer{primitive="static"})
	mesh:geometry.Mesh; defer geometry.destroy_mesh(&mesh)
	append(&mesh.vertices,geometry.Vertex{position={1,2,-5},normal={0,0,1}},geometry.Vertex{position={2,2,-5},normal={0,0,1}},geometry.Vertex{position={1,3,-5},normal={0,0,1}}); append(&mesh.indices,0,1,2)
	testing.expect(t,ecs.set_static_mesh(&w,e,mesh,collidable=false))
	bounds,ok:=scene_selection_bounds_3d(&w,&manager,e,camera,{100,100},0.1,100)
	testing.expect(t,ok && selection_rect_close_3d(bounds,{60,20,10,10}),"static geometry uses current CPU vertex bounds")
	for &vertex in mesh.vertices {vertex.position[1]+=1}
	testing.expect(t,ecs.set_static_mesh(&w,e,mesh,collidable=false))
	bounds,ok=scene_selection_bounds_3d(&w,&manager,e,camera,{100,100},0.1,100)
	testing.expect(t,ok && selection_rect_close_3d(bounds,{60,10,10,10}),"CPU replacement changes selection without GPU upload")
	model:=ecs.create_entity(&w); ecs.add(&w,&r,model,ecs.Transform{position={0,0,-5},scale={1,1,1}}); ecs.add(&w,&r,model,ecs.ModelRenderer{model="fixture.obj"})
	_,ok=scene_selection_bounds_3d(&w,&manager,model,camera,{100,100},0.1,100)
	testing.expect(t,!ok && len(manager.models)==0,"bounds never register or load a missing model")
	manager.models["fixture.obj"]={revision=1}
	assets.cache_model_bounds(&manager,"fixture.obj",{{2,-2,-0.5},{3,0,0.5}})
	bounds,ok=scene_selection_bounds_3d(&w,&manager,model,camera,{100,100},0.1,100)
	testing.expect(t,ok && selection_rect_close_3d(bounds,{70,50,10,20}),"asymmetric cached local model bounds are preserved")
	ecs.add(&w,&r,model,ecs.SphereRenderer{radius=1})
	bounds,ok=scene_selection_bounds_3d(&w,&manager,model,camera,{100,100},0.1,100)
	testing.expect(t,ok && selection_rect_close_3d(bounds,{40,40,40,30}),"sphere and model render components contribute a union")
}

@(test)
selection_3d_rejects_invalid_cameras_and_entities :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	e:=ecs.create_entity(&w); ecs.add(&w,&r,e,ecs.Transform{scale={1,1,1}}); ecs.add(&w,&r,e,ecs.MeshRenderer{primitive="cube"})
	camera:=rl.Camera3D{position={0,0,10},up={0,1,0},fovy=60,projection=.PERSPECTIVE}
	_,ok:=scene_selection_bounds_3d(nil,nil,e,camera,{800,600},0.1,100); testing.expect(t,!ok)
	_,ok=scene_selection_bounds_3d(&w,nil,0,camera,{800,600},0.1,100); testing.expect(t,!ok)
	_,ok=scene_selection_bounds_3d(&w,nil,e,camera,{0,600},0.1,100); testing.expect(t,!ok)
	_,ok=scene_selection_bounds_3d(&w,nil,e,camera,{800,600},10,1); testing.expect(t,!ok)
	nan:=transmute(f32)u32(0x7fc00000)
	camera.target={nan,0,0}
	_,ok=scene_selection_bounds_3d(&w,nil,e,camera,{800,600},0.1,100); testing.expect(t,!ok)
	camera.target=camera.position
	_,ok=scene_selection_bounds_3d(&w,nil,e,camera,{800,600},0.1,100); testing.expect(t,!ok)
	camera.target={}; camera.up={0,0,1}
	_,ok=scene_selection_bounds_3d(&w,nil,e,camera,{800,600},0.1,100); testing.expect(t,!ok)
}

@(test)
selection_3d_projection_matches_raylib_for_tilted_camera :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	e:=ecs.create_entity(&w); ecs.add(&w,&r,e,ecs.Transform{position={0.25,-0.5,0.75},scale={1,1,1}}); ecs.add(&w,&r,e,ecs.MeshRenderer{primitive="cube"})
	camera:=rl.Camera3D{position={3,4,9},target={0.5,-0.25,0},up={0.25,1,0.1},fovy=60,projection=.PERSPECTIVE}
	for mode in ([2]rl.CameraProjection{.PERSPECTIVE,.ORTHOGRAPHIC}) {
		camera.projection=mode
		camera.fovy=60 if mode==.PERSPECTIVE else 6
		bounds,ok:=scene_selection_bounds_3d(&w,nil,e,camera,{913,517},0.1,100)
		testing.expect(t,ok)
		minimum,maximum:=[2]f32{913,517},[2]f32{}
		for index in 0..<8 {
			point:=[3]f32{-0.25,-1,0.25}
			for axis in 0..<3 {if index & (1<<u32(axis))!=0 {point[axis]+=1}}
			screen:=rl.GetWorldToScreenEx(point,camera,913,517)
			for axis in 0..<2 {minimum[axis]=min(minimum[axis],screen[axis]); maximum[axis]=max(maximum[axis],screen[axis])}
		}
		testing.expect(t,selection_rect_close_3d(bounds,{minimum[0],minimum[1],maximum[0]-minimum[0],maximum[1]-minimum[1]}),"CPU highlight projection agrees with raylib for an off-axis camera, rolled up vector, and wide viewport")
	}
}

@(test)
selection_3d_keeps_extreme_finite_projection_bounded :: proc(t:^testing.T) {
	w:=ecs.init(); defer ecs.destroy(&w)
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); ecs.register_builtin_components(&r)
	e:=ecs.create_entity(&w); ecs.add(&w,&r,e,ecs.Transform{scale={1,1,1}}); ecs.add(&w,&r,e,ecs.MeshRenderer{primitive="cube"})
	camera:=rl.Camera3D{position={0,0,10},up={0,1,0},fovy=transmute(f32)u32(1),projection=.PERSPECTIVE}
	bounds,ok:=scene_selection_bounds_3d(&w,nil,e,camera,{800,600},0,100)
	testing.expect(t,ok && selection_rect_close_3d(bounds,{0,0,800,600}),"tiny positive fovy saturates to viewport without f32 overflow")
	camera.fovy=60
	ecs.set_transform(&w,e,ecs.Transform{scale={1e30,1e30,1e30}})
	bounds,ok=scene_selection_bounds_3d(&w,nil,e,camera,{800,600},0.1,100)
	testing.expect(t,ok && selection_rect_close_3d(bounds,{0,0,800,600}),"huge finite bounds crossing both clip planes remain finite")
}
