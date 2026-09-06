package main

import "core:fmt"
import "core:encoding/json"
import "rune:ecs"

main :: proc() {
	validate_reparenting()
	validate_subtree_destruction()
	validate_metadata_changes()
	fmt.println("Hierarchy and entity identity validation passed")
}

validate_reparenting :: proc() {
	world := ecs.init()
	defer ecs.destroy(&world)
	root := ecs.create_entity(&world)
	child := ecs.create_entity(&world)
	grandchild := ecs.create_entity(&world)
	assert(ecs.set_parent(&world, child, root))
	assert(ecs.set_parent(&world, grandchild, child))
	assert(!ecs.set_parent(&world, root, grandchild))
	assert(!ecs.set_parent(&world, child, grandchild))
	assert(!ecs.set_parent(&world, child, child))
	assert(len(ecs.root_entities(&world)) == 1)
	parent, found := ecs.get_parent(&world, child)
	assert(found && parent == root)
	assert(ecs.set_parent(&world, child, root))
	assert(!world.hierarchy_dirty)
	assert(ecs.set_parent(&world, grandchild, 0))
	assert(len(ecs.root_entities(&world)) == 2)
	assert(ecs.set_parent(&world, root, grandchild))
	assert(!ecs.destroy_entity(&world, grandchild, false))
	assert(world.entity_count == 3)
	assert(ecs.destroy_entity(&world, grandchild))
	assert(world.entity_count == 0 && len(ecs.root_entities(&world)) == 0)
	assert(!ecs.set_parent(&world, child, root))
}

validate_subtree_destruction :: proc() {
	world := ecs.init()
	defer ecs.destroy(&world)
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	survivor := ecs.create_entity(&world)
	root := ecs.create_entity(&world)
	for _ in 0 ..< 4000 {
		child := ecs.create_entity(&world)
		assert(ecs.set_parent(&world, child, root))
		assert(ecs.add_component(&world, &registry, child, "Transform", json.Object{}))
		grandchild := ecs.create_entity(&world)
		assert(ecs.set_parent(&world, grandchild, child))
	}
	assert(ecs.destroy_entity(&world, root))
	assert(world.entity_count == 1 && ecs.is_alive(&world, survivor))
	assert(len(world.transforms) == 0)
	roots := ecs.root_entities(&world)
	assert(len(roots) == 1 && roots[0] == survivor)
	assert(len(ecs.child_entities(&world, root)) == 0)
	assert(!ecs.destroy_entity(&world, root))
	assert(ecs.destroy_entity(&world, survivor, false))
}

validate_metadata_changes :: proc() {
	world := ecs.init()
	defer ecs.destroy(&world)
	first := ecs.create_entity(&world)
	second := ecs.create_entity(&world)
	assert(ecs.set_entity_metadata(&world, first, "old", "First", "", ecs.Default_Layer_Mask))
	assert(ecs.set_entity_metadata(&world, second, "taken", "Second", "", ecs.Default_Layer_Mask))
	assert(!ecs.set_entity_metadata(&world, first, "taken", "Rejected", "", ecs.Default_Layer_Mask))
	resolved, found := ecs.find_entity_by_id(&world, "old")
	assert(found && resolved == first)
	name, _ := ecs.entity_name(&world, first)
	assert(name == "First")
	assert(ecs.set_entity_metadata(&world, first, "new", "First", "", ecs.Default_Layer_Mask))
	_, found = ecs.find_entity_by_id(&world, "old")
	assert(!found)
	resolved, found = ecs.find_entity_by_id(&world, "new")
	assert(found && resolved == first)
	assert(ecs.set_entity_metadata(&world, second, "old", "Second", "", ecs.Default_Layer_Mask))
	_, found = ecs.find_entity_by_id(&world, "taken")
	assert(!found)
	assert(ecs.set_entity_metadata(&world, first, "", "First", "", ecs.Default_Layer_Mask))
	_, found = ecs.find_entity_by_id(&world, "new")
	assert(!found)
	assert(ecs.destroy_entity(&world, first))
	resolved, found = ecs.find_entity_by_id(&world, "old")
	assert(found && resolved == second)
}
