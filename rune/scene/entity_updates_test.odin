package scene

import "core:encoding/json"
import "core:testing"
import "rune:ecs"

@(test)
entity_update_rejects_conflicts_with_components_added_at_runtime :: proc(t: ^testing.T) {
	world := ecs.init()
	defer ecs.destroy(&world)
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	if !testing.expect(t, ecs.register_builtin_components(&registry)) {return}
	before := Entity_Data{id = "panel", components = make(map[string]json.Value, context.temp_allocator)}
	before.components["Transform"], _ = ecs.runtime_json(ecs.default_transform())
	root, created := instantiate_entity_tree(&world, &registry, before, 0, nil)
	if !testing.expect(t, created) {return}
	collider := ecs.BoxCollider{size = {1, 1, 1}}
	if !testing.expect(t, ecs.add(&world, &registry, root, collider)) {return}

	after := Entity_Data{id = "panel", components = make(map[string]json.Value, context.temp_allocator),
		children = []Entity_Data{{id = "panel/new"}}}
	pose := ecs.default_transform()
	pose.position.x = 3
	after.components["Transform"], _ = ecs.runtime_json(pose)
	after.components["Terrain"], _ = ecs.runtime_json(ecs.Terrain{asset = "unused.terrain.json"})
	updates := []Entity_Update{{entity = root, before = before, after = after}}
	defer clear_load_error()
	version := world.component_change_version
	testing.expect(t, !apply_entity_updates(&world, &registry, updates, nil))
	unchanged_pose, _ := ecs.get_transform(&world, root)
	_, child_created := ecs.find_entity_by_id(&world, "panel/new")
	testing.expect(t, unchanged_pose.position.x == 0 && !child_created && world.component_change_version == version,
		"the runtime collider conflict is rejected before any live changes")

	if !testing.expect(t, ecs.remove_component(&world, root, "BoxCollider")) {return}
	if !testing.expect(t, apply_entity_updates(&world, &registry, updates, nil)) {return}
	edited_pose, _ := ecs.get_transform(&world, root)
	_, child_created = ecs.find_entity_by_id(&world, "panel/new")
	testing.expect(t, edited_pose == pose && child_created && ecs.has_component_data(&world, root, "Terrain"))
}
