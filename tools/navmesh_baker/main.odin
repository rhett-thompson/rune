package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "rune:ecs"
import "rune:navigation"
import "rune:scene"

Config :: struct {
	project_root,scene,output: string,
	settings: navigation.Bake_Settings_3D,
}
resolve :: proc(root,path:string) -> string {
	if filepath.is_abs(path) {return path}
	return filepath.join({root,path},context.temp_allocator) or_else ""
}
fail :: proc(message:string) {fmt.eprintln("Navmesh bake failed:",message);os.exit(1)}
main :: proc() {
	if len(os.args)!=2 {fmt.eprintln("Usage: navmesh_baker path/to/level.navbake.json");os.exit(2)}
	path:=os.args[1]
	bytes,read_error:=os.read_entire_file(path,context.temp_allocator)
	if read_error!=nil {fail("could not read bake config")}
	value:json.Value
	if json.unmarshal(bytes,&value,allocator=context.temp_allocator)!=nil {fail("invalid bake config JSON")}
	object,ok:=value.(json.Object);if !ok {fail("bake config must be an object")}
	for key in object {if key!="$schema" && key!="project_root" && key!="scene" && key!="output" && key!="settings" {fail(fmt.tprintf("unknown bake config field: %s",key))}}
	if field,exists:=object["settings"];exists {
		settings,is_object:=field.(json.Object);if !is_object {fail("settings must be an object")}
		for key in settings {if key!="cell_size" && key!="agent_radius" && key!="agent_height" && key!="max_slope" {fail(fmt.tprintf("unknown bake setting: %s",key))}}
	}
	config:=Config{project_root=".",settings=navigation.Default_Bake_Settings_3D}
	if json.unmarshal(bytes,&config,allocator=context.temp_allocator)!=nil || config.scene=="" || config.output=="" || !navigation.bake_settings_valid_3d(config.settings) {fail("invalid config: scene, output and valid settings are required")}
	root:=resolve(filepath.dir(path),config.project_root)
	output:=resolve(root,config.output)
	scene_path:=resolve(root,config.scene)
	if !strings.has_suffix(output,".navmesh.json") || output==scene_path {fail("output must be a separate .navmesh.json asset")}
	registry:=ecs.init_registry();defer ecs.destroy_registry(&registry)
	if !ecs.register_builtin_components(&registry) {fail("could not register built-in components")}
	// Use the project's named layers when loading scenes, without initializing
	// a window or requiring unrelated renderer/input assets to be available.
	project_path:=resolve(root,"project.json")
	project:struct {layers:map[string]u8}
	if os.exists(project_path) {
		project_bytes,project_error:=os.read_entire_file(project_path,context.temp_allocator)
		if project_error!=nil || json.unmarshal(project_bytes,&project,allocator=context.temp_allocator)!=nil {fail("could not read project layer table")}
		for name,index in project.layers {if name=="" || index>63 || (index==0 && name!="Default") {fail("invalid project layer table")}}
	}
	world,loaded:=scene.load_with_layers(scene_path,&registry,project.layers)
	if !loaded {fail(scene.last_load_error())};defer ecs.destroy(&world)
	mesh,stats,error:=ecs.bake_navigation_world_3d(&world,root,config.settings)
	if error!="" {fail(error)};defer navigation.destroy_mesh_3d(&mesh)
	if err:=navigation.write_mesh_3d(output,&mesh);err!="" {fail(err)}
	fmt.printf("Baked %s\n%d input triangles, %d cells, %d spans, %d walkable cells, %d output triangles\n",output,stats.input_triangles,stats.cells,stats.spans,stats.walkable_cells,stats.output_triangles)
}
