package ecs

// set_parent makes child inherit its parent's scene transform. Passing Entity(0)
// makes the entity a scene root.
set_parent :: proc(world: ^World, child, parent: Entity) -> bool {
	if !is_alive(world, child) ||
	   (parent != Entity(0) && !is_alive(world, parent)) ||
	   child == parent {
		return false
	}
	// Walk the proposed parent's ancestry before changing the existing tree.
	// A cycle would hide entities from root traversal and break destruction.
	ancestor := parent
	for ancestor != Entity(0) {
		if ancestor == child {return false}
		ancestor = world.parents[ancestor]
	}
	if world.parents[child] == parent {return true}
	if parent == Entity(0) {
		delete_key(&world.parents, child)
	} else {
		world.parents[child] = parent
	}
	world.hierarchy_dirty = true
	return true
}

get_parent :: proc(world: ^World, entity: Entity) -> (Entity, bool) {
	parent, found := world.parents[entity]
	return parent, found
}

// root_entities and child_entities expose cached hierarchy indexes to render
// systems. The indexes are rebuilt only when entities are created or reparented.
root_entities :: proc(world: ^World) -> []Entity {
	ensure_hierarchy_indexes(world)
	return world.roots[:]
}

child_entities :: proc(world: ^World, parent: Entity) -> []Entity {
	ensure_hierarchy_indexes(world)
	children, found := world.children_by_parent[parent]
	if !found {return nil}
	return children[:]
}

ensure_hierarchy_indexes :: proc(world: ^World) {
	if !world.hierarchy_dirty {return}
	// Reparenting is uncommon. Replacing these compact indexes keeps the hot
	// rendering path allocation-free and avoids a full parent-map scan per node.
	delete(world.roots)
	for _, children in world.children_by_parent {delete(children)}
	delete(world.children_by_parent)
	world.roots = make([dynamic]Entity)
	world.children_by_parent = make(map[Entity][dynamic]Entity)
	for entity in world.entities {
		parent, has_parent := world.parents[entity]
		if !has_parent {
			append(&world.roots, entity)
			continue
		}
		children, found := world.children_by_parent[parent]
		if !found {children = make([dynamic]Entity)}
		append(&children, entity)
		world.children_by_parent[parent] = children
	}
	world.hierarchy_dirty = false
}
