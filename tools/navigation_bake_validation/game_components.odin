package main

import "core:fmt"
import "core:os"
import "core:strings"
import "rune:ecs"
import "rune:navigation"
import "rune:scene"

Bake_Ownership :: struct {
	owner: string,
	priority: i32,
}

bake_skipped_components: [3]bool
bake_skip_count: int

record_bake_skipped_component :: proc(entity_id, component_name: string) {
	check(component_name == "Ownership", "skip callback identifies the omitted component")
	index: int
	switch entity_id {
	case "supply_crate": index = 0
	case "supply_crate/marker": index = 1
	case "supply_crate/marker/detail": index = 2
	case: check(false, "skip callback uses fully resolved prefab entity IDs")
	}
	check(!bake_skipped_components[index], "each omitted component is reported once")
	bake_skipped_components[index] = true
	bake_skip_count += 1
}

write_bake_game_fixture :: proc(path, contents: string) {
	check(os.write_entire_file(path, contents) == nil, "write game-component bake fixture")
}

bake_game_entity :: proc(world: ^ecs.World, id: string) -> ecs.Entity {
	entity, found := ecs.find_entity_by_id(world, id)
	check(found, "game-component bake retains resolved entity IDs")
	return entity
}

validate_scene_game_components :: proc() {
	scene_file :: "build/bake-game-components.scene.json"
	write_bake_game_fixture("build/bake-game-components.prefab.json", `{
		"name":"Crate", "components":{
			"Transform":{"position":[2,1.5,0]}, "BoxCollider":{"size":[2,3,2]},
			"Ownership":{"owner":"prefab"}
		}, "children":[{"id":"marker","prefab":"bake-game-child.prefab.json"}]
	}`)
	write_bake_game_fixture("build/bake-game-child.prefab.json", `{
		"name":"Marker", "layers":["Geometry"],
		"components":{"Transform":{"position":[3,0,0]},"Ownership":{"owner":"nested prefab"}},
		"children":[{"id":"detail","components":{
			"Transform":{"position":[1,50,0]}, "BoxCollider":{"size":[2,100,2]},
			"Ownership":{"owner":"detail"}
		}}]
	}`)
	write_bake_game_fixture(scene_file, `{
		"name":"Game component bake", "entities":[
			{"id":"floor","components":{"Transform":{"position":[0,-0.5,0]},"BoxCollider":{"size":[20,1,20]}}},
			{"id":"supply_crate","prefab":"bake-game-components.prefab.json","layers":["Gameplay"],
			 "component_overrides":{"Ownership":{"owner":"scene"}},
			 "child_overrides":{"marker/detail":{"enabled":false,"component_overrides":{"Ownership":{"owner":"override"}}}}}
		]
	}`)
	layers := make(map[string]u8); defer delete(layers)
	layers["Gameplay"] = 1
	layers["Geometry"] = 2
	registry := ecs.init_registry(); defer ecs.destroy_registry(&registry)
	check(ecs.register_builtin_components(&registry), "game-component registry")
	defer scene.clear_load_error()

	bake_skipped_components = {}
	bake_skip_count = 0
	options := scene.Load_Options{
		skip_unregistered_components = true,
		on_skipped_component = record_bake_skipped_component,
	}
	world, loaded := scene.load_with_layers(scene_file, &registry, layers, options)
	check(loaded, scene.last_load_error()); defer ecs.destroy(&world)
	check(world.entity_count == 4 && bake_skip_count == 3, "tool load retains all entities and reports all custom components")
	for skipped in bake_skipped_components {check(skipped, "skip callback visits nested prefab components")}
	crate := bake_game_entity(&world, "supply_crate")
	marker := bake_game_entity(&world, "supply_crate/marker")
	detail := bake_game_entity(&world, "supply_crate/marker/detail")
	check(world.parents[marker] == crate && world.parents[detail] == marker, "tool load retains prefab hierarchy")
	check(world.layer_masks[crate] == 2 && world.layer_masks[marker] == 4, "tool load retains authored layers")
	check(!ecs.is_locally_enabled(&world, detail) && !ecs.is_enabled(&world, detail), "tool load retains child activation override")
	pose, has_pose := ecs.get_transform(&world, crate)
	box, has_box := ecs.get_box_collider(&world, crate)
	check(has_pose && pose.position == [3]f32{2,1.5,0} && has_box && box.size == [3]f32{2,3,2}, "tool load retains known static geometry")
	check(ecs.has_component_data(&world, detail, "BoxCollider"), "disabled geometry remains authored but inactive")
	for entity in world.entities {check(!ecs.has_component_data(&world, entity, "Ownership"), "skipped components are absent from runtime storage")}
	check(!ecs.has_component(&registry, "Ownership"), "tool load does not register unknown components")
	validate_game_component_bake_equivalence(&world, &registry)

	// The opt-in applies to this call, not the shared registry or future loads.
	strict, strict_loaded := scene.load_with_layers(scene_file, &registry, layers)
	defer ecs.destroy(&strict)
	check(!strict_loaded && strings.contains(scene.last_load_error(), "unregistered component 'Ownership'"), "default layered loading stays strict after a tool load")
	write_bake_game_fixture("build/bake-game-strict.scene.json", `{"name":"Strict","entities":[{"id":"custom","components":{"Ownership":{}}}]}`)
	plain, plain_loaded := scene.load("build/bake-game-strict.scene.json", &registry)
	defer ecs.destroy(&plain)
	check(!plain_loaded && strings.contains(scene.last_load_error(), "unregistered component 'Ownership'"), "plain scene loading stays strict")
	validate_game_component_load_failures(&registry, layers)

	check(ecs.register_component_type(&registry, "Ownership", Bake_Ownership, Bake_Ownership{owner = "default", priority = 7}), "register game component normally")
	typed, typed_loaded := scene.load_with_layers(scene_file, &registry, layers)
	check(typed_loaded, scene.last_load_error()); defer ecs.destroy(&typed)
	ownership_ids := [3]string{"supply_crate", "supply_crate/marker", "supply_crate/marker/detail"}
	owners := [3]string{"scene", "nested prefab", "override"}
	for id, index in ownership_ids {
		value, found := ecs.get(&typed, bake_game_entity(&typed, id), Bake_Ownership)
		check(found && value.priority == 7 && value.owner == owners[index], "registered game components retain authored overrides and typed defaults")
	}
	bake_skip_count = 0
	registered, registered_loaded := scene.load_with_layers(scene_file, &registry, layers, options)
	check(registered_loaded && bake_skip_count == 0, "tool option still instantiates registered components")
	defer ecs.destroy(&registered)
}

validate_game_component_bake_equivalence :: proc(world: ^ecs.World, registry: ^ecs.Component_Registry) {
	// The independent control contains only the active geometry. The disabled
	// prefab descendant must not contribute a tall obstacle or new walkable roof.
	write_bake_game_fixture("build/bake-game-stripped.scene.json", `{
		"name":"Geometry control", "entities":[
			{"id":"floor","components":{"Transform":{"position":[0,-0.5,0]},"BoxCollider":{"size":[20,1,20]}}},
			{"id":"supply_crate","components":{"Transform":{"position":[2,1.5,0]},"BoxCollider":{"size":[2,3,2]}}}
		]
	}`)
	control, loaded := scene.load("build/bake-game-stripped.scene.json", registry)
	check(loaded, scene.last_load_error()); defer ecs.destroy(&control)
	mesh, _, error := ecs.bake_navigation_world_3d(world, ".")
	check(error == "", error); defer navigation.destroy_mesh_3d(&mesh)
	stripped, _, stripped_error := ecs.bake_navigation_world_3d(&control, ".")
	check(stripped_error == "", stripped_error); defer navigation.destroy_mesh_3d(&stripped)
	check(len(mesh.triangles) > 0 && route(&mesh, {-5,0,0}, {7,0,0}) == .Complete, "game-component scene produces a usable bake")
	check(navigation.write_mesh_3d("build/bake-game-components.navmesh.json", &mesh) == "", "write game-component navmesh")
	check(navigation.write_mesh_3d("build/bake-game-stripped.navmesh.json", &stripped) == "", "write stripped control navmesh")
	actual, actual_error := os.read_entire_file("build/bake-game-components.navmesh.json", context.allocator); defer delete(actual)
	expected, expected_error := os.read_entire_file("build/bake-game-stripped.navmesh.json", context.allocator); defer delete(expected)
	check(actual_error == nil && expected_error == nil && string(actual) == string(expected), "skipping passive game components produces byte-identical baked output")
}

validate_game_component_load_failures :: proc(registry: ^ecs.Component_Registry, layers: map[string]u8) {
	Case :: struct {entities, diagnostic: string}
	cases := [5]Case{
		{`[{"id":"custom","components":{"Ownership":3}}]`, "component 'Ownership' must be an object"},
		{`[{"id":"bad","components":{"Transform":{"position":"bad"},"Ownership":{}}}]`, "invalid data for component 'Transform'"},
		{`[{"id":"same","components":{"Ownership":{}}},{"id":"same"}]`, "duplicates another entity ID"},
		{`[{"id":"bad","layers":["Missing"],"components":{"Ownership":{}}}]`, "is not declared by project.json"},
		{`[{"id":"bad","prefab":"bake-game-components.prefab.json","child_overrides":{"missing":{"enabled":false}}}]`, "does not exist"},
	}
	for test in cases {
		contents := fmt.aprintf("%s%s%s", `{"name":"Invalid game component scene","entities":`, test.entities, "}")
		defer delete(contents)
		write_bake_game_fixture("build/bake-game-invalid.scene.json", contents)
		world, loaded := scene.load_with_layers("build/bake-game-invalid.scene.json", registry, layers, {skip_unregistered_components = true})
		check(!loaded && strings.contains(scene.last_load_error(), test.diagnostic),
			fmt.tprintf("tool loading must reject invalid data: expected '%s', loaded=%v, diagnostic='%s'", test.diagnostic, loaded, scene.last_load_error()))
		ecs.destroy(&world)
	}
}
