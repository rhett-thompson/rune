package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "rune:assets"
import "rune:console"
import rune "rune:core"
import "rune:ecs"
import "rune:navigation"
import "rune:scene"

Course_Root :: "examples/navigation_3d"
bake_failed:bool
baked_triangles:int

course_bake_settings :: proc() -> (navigation.Bake_Settings_3D,string) {
	bytes,read_error:=os.read_entire_file(Course_Root+"/course.navbake.json",context.temp_allocator)
	if read_error!=nil {return {},"could not read course.navbake.json"}
	value:json.Value
	if json.unmarshal(bytes,&value,allocator=context.temp_allocator)!=nil {return {},"invalid bake config JSON"}
	object,ok:=value.(json.Object);if !ok {return {},"bake config must be an object"}
	settings:=navigation.Default_Bake_Settings_3D
	if field,exists:=object["settings"];exists {
		if !ecs.json_shape_matches_type(field,navigation.Bake_Settings_3D) {return {},"invalid bake settings"}
		encoded,error:=json.marshal(field,allocator=context.temp_allocator)
		if error!=nil || json.unmarshal(encoded,&settings,allocator=context.temp_allocator)!=nil {return {},"invalid bake settings"}
	}
	if !navigation.bake_settings_valid_3d(settings) {return {},"invalid bake settings"}
	return settings,""
}

// Bake the actual world (including live console edits) into its referenced asset.
// Nothing is replaced until geometry generation and serialization both succeed.
bake_course_world :: proc(world:^ecs.World,root:string,settings:navigation.Bake_Settings_3D) -> (navigation.Bake_Stats_3D,string) {
	entity,found:=ecs.find_entity_by_id(world,"navigation");if !found {return {},"navigation entity is missing"}
	config,ok:=ecs.get(world,entity,ecs.NavMesh3D);if !ok {return {},"NavMesh3D is missing"}
	if !strings.has_suffix(config.asset,".navmesh.json") {return {},"navigation output must end in .navmesh.json"}
	mesh,stats,error:=ecs.bake_navigation_world_3d(world,root,settings)
	if error!="" {return stats,error};defer navigation.destroy_mesh_3d(&mesh)
	path:=config.asset
	if !filepath.is_abs(path) {path=filepath.join({root,path},context.temp_allocator) or_else ""}
	return stats,navigation.write_mesh_3d(path,&mesh)
}

// Run before engine project validation, so a checkout without a generated
// navmesh can still start. This stage needs no window or physics context.
bake_course_startup :: proc() -> bool {
	settings,error:=course_bake_settings()
	if error!="" {fmt.eprintln("Navigation bake failed:",error);bake_failed=true;return false}
	r:=ecs.init_registry();defer ecs.destroy_registry(&r)
	if !ecs.register_builtin_components(&r) {bake_failed=true;return false}
	w,loaded:=scene.load(Course_Root+"/scenes/main.scene.json",&r)
	if !loaded {fmt.eprintln(scene.last_load_error());bake_failed=true;return false};defer ecs.destroy(&w)
	stats,bake_error:=bake_course_world(&w,Course_Root,settings)
	bake_failed=bake_error!=""
	if bake_failed {fmt.eprintln("Navigation bake failed:",bake_error);return false}
	baked_triangles=stats.output_triangles
	fmt.printf("Baked navigation: %d triangles from scene geometry\n",baked_triangles)
	return true
}

rebake_course :: proc(game:^rune.Engine,world:^ecs.World) -> bool {
	settings,error:=course_bake_settings()
	entity,found:=ecs.find_entity_by_id(world,"navigation")
	old_mesh,_:=ecs.navigation_mesh_3d(world,entity)
	closed:=ramp_is_closed(old_mesh)
	stats:navigation.Bake_Stats_3D
	if error=="" {stats,error=bake_course_world(world,game.assets.root,settings)}
	bake_failed=error!=""
	if bake_failed {console.error(rune.developer_console(game),fmt.tprintf("Navigation bake failed: %s. Previous mesh retained.",error));return false}
	if found {
		config,_:=ecs.get(world,entity,ecs.NavMesh3D)
		// Explicit reload avoids filesystem timestamp granularity delaying the bake.
		assets.load_navmesh(&game.assets,config.asset,.Reload)
		ecs.sync_navigation_3d(world,&game.assets)
		if closed {toggle_ramp(world)}
	}
	baked_triangles=stats.output_triangles
	console.info(rune.developer_console(game),fmt.tprintf("Baked navigation: %d triangles. Ramp %s.",baked_triangles,"closed" if closed else "open"))
	return true
}
rebake_command :: proc(c:^console.Console,args:string) {
	game:=(^rune.Engine)(c.user_data)
	rebake_course(game,&game.active_world)
}
reload_course :: proc(game:^rune.Engine,world:^ecs.World) {
	enter(game,world)
	rebake_course(game,world)
}
