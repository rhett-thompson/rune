package replication

import "core:math"
import "core:testing"
import "rune:ecs"

test_registry :: proc() -> ecs.Component_Registry {
	registry := ecs.init_registry()
	assert(ecs.register_builtin_components(&registry) && register(&registry))
	return registry
}

test_add_player :: proc(world: ^ecs.World, registry: ^ecs.Component_Registry, state: State) -> ecs.Entity {
	entity := ecs.create_entity(world)
	assert(ecs.add(world, registry, entity, Identity{state.id, state.owner_peer}))
	assert(ecs.add(world, registry, entity, ecs.Transform{position = {state.position[0], state.position[1], 0}, scale = {1, 1, 1}}))
	return entity
}

@(test)
replica_spawn_update_remove_and_rejoin :: proc(t: ^testing.T) {
	registry := test_registry(); defer ecs.destroy_registry(&registry)
	world := ecs.init(); defer ecs.destroy(&world)
	unrelated := ecs.create_entity(&world)
	replica: Replica
	first := Snapshot{tick = 1, count = 2, states = {0 = State{9001, 21, {2, 3}}, 1 = State{9002, 22, {4, 5}}}}
	testing.expect(t, apply_snapshot(&replica, &world, &registry, first) && world.entity_count == 3)
	first_entity, found := entity_for_id(&replica, 9001)
	second_entity, second_found := entity_for_id(&replica, 9002)
	testing.expect(t, found && second_found && first_entity != second_entity && ecs.entity_index(first_entity) != 9001,
		"host network IDs never become runtime ECS indices")
	first_transform, _ := ecs.get(&world, first_entity, ecs.Transform)
	testing.expect(t, first_transform.position == [3]f32{2, 3, 0} && first_transform.scale == [3]f32{1, 1, 1})
	first_transform.rotation = {0, 0, 30}; first_transform.scale = {2, 2, 1}
	assert(ecs.set(&world, first_entity, first_transform))
	second := Snapshot{tick = 2, count = 1, states = {0 = State{9001, 21, {6, 7}}}}
	testing.expect(t, apply_snapshot(&replica, &world, &registry, second) && !ecs.is_alive(&world, second_entity))
	updated_entity, _ := entity_for_id(&replica, 9001)
	updated_transform, _ := ecs.get(&world, first_entity, ecs.Transform)
	testing.expect(t, updated_entity == first_entity && updated_transform.position == [3]f32{6, 7, 0})
	testing.expect(t, updated_transform.rotation == first_transform.rotation && updated_transform.scale == first_transform.scale,
		"game-controlled appearance survives position updates")
	rejoined := first; rejoined.tick = 3; rejoined.states[1].id = 9003; rejoined.states[1].owner_peer = 23
	testing.expect(t, apply_snapshot(&replica, &world, &registry, rejoined))
	rejoined_entity, _ := entity_for_id(&replica, 9003)
	testing.expect(t, rejoined_entity != second_entity && ecs.is_alive(&world, rejoined_entity))
	_, old_found := entity_for_id(&replica, 9002)
	testing.expect(t, !old_found)
	clear(&replica, &world)
	testing.expect(t, world.entity_count == 1 && ecs.is_alive(&world, unrelated) && replica == Replica{})
	testing.expect(t, apply_snapshot(&replica, &world, &registry, Snapshot{tick = 0}), "clear resets tick history for a new room")
}

@(test)
rejected_snapshots_are_atomic :: proc(t: ^testing.T) {
	registry := test_registry(); defer ecs.destroy_registry(&registry)
	world := ecs.init(); defer ecs.destroy(&world)
	replica: Replica
	initial := Snapshot{tick = 100, count = 1, states = {0 = State{11, 7, {10, 20}}}}
	assert(apply_snapshot(&replica, &world, &registry, initial))
	before := replica
	version := ecs.change_version(&world)
	for tick in ([3]u32{100, 99, 0}) {
		stale := initial; stale.tick = tick; stale.states[0].position = {-100, 200}
		testing.expect(t, !apply_snapshot(&replica, &world, &registry, stale))
	}
	invalid := initial; invalid.tick = 101; invalid.count = 2
	invalid.states[0].position = {-100, 200}; invalid.states[1] = initial.states[0]
	testing.expect(t, !apply_snapshot(&replica, &world, &registry, invalid), "a later duplicate must not apply the earlier state")
	invalid.count = 1; invalid.states[0].position[0] = math.nan_f32()
	testing.expect(t, !apply_snapshot(&replica, &world, &registry, invalid))
	invalid = initial; invalid.tick = 101; invalid.states[0].owner_peer = 0
	testing.expect(t, !apply_snapshot(&replica, &world, &registry, invalid))
	transform, _ := ecs.get(&world, replica.entities[0], ecs.Transform)
	testing.expect(t, replica == before && world.entity_count == 1 && ecs.change_version(&world) == version && transform.position == [3]f32{10, 20, 0})
	wrong_registry := ecs.init_registry(); defer ecs.destroy_registry(&wrong_registry)
	assert(ecs.register_builtin_components(&wrong_registry))
	valid := initial; valid.tick = 101; valid.count = 2; valid.states[1] = State{12, 8, {3, 4}}
	testing.expect(t, !apply_snapshot(&replica, &world, &wrong_registry, valid))
	testing.expect(t, replica == before && world.entity_count == 1 && ecs.change_version(&world) == version)
	world.next_entity = 0
	testing.expect(t, !apply_snapshot(&replica, &world, &registry, valid))
	testing.expect(t, replica == before && world.entity_count == 1 && ecs.change_version(&world) == version,
		"entity ID exhaustion is detected before existing players are updated")
}

@(test)
replica_does_not_adopt_stale_or_edited_entities :: proc(t: ^testing.T) {
	registry := test_registry(); defer ecs.destroy_registry(&registry)
	world := ecs.init()
	replica: Replica
	initial := Snapshot{tick = 1, count = 1, states = {0 = State{500, 8, {1, 2}}}}
	assert(apply_snapshot(&replica, &world, &registry, initial))
	original := replica.entities[0]
	assert(ecs.destroy_entity(&world, original))
	unrelated := ecs.create_entity(&world)
	assert(ecs.add(&world, &registry, unrelated, ecs.Transform{position = {55, 66, 0}, scale = {1, 1, 1}}))
	next := initial; next.tick = 2
	testing.expect(t, apply_snapshot(&replica, &world, &registry, next))
	testing.expect(t, replica.entities[0] != original && replica.entities[0] != unrelated && ecs.is_alive(&world, unrelated))
	stale_handle := replica.entities[0]
	stale_index := ecs.entity_index(stale_handle)
	ecs.destroy(&world)
	world = ecs.init(); defer ecs.destroy(&world)
	world.next_entity = stale_index
	reused := test_add_player(&world, &registry, State{500, 8, {55, 66}})
	testing.expect(t, ecs.entity_index(reused) == stale_index && ecs.entity_generation(reused) != ecs.entity_generation(stale_handle))
	next.tick = 3
	testing.expect(t, apply_snapshot(&replica, &world, &registry, next) && replica.entities[0] != reused)
	reused_transform, _ := ecs.get(&world, reused, ecs.Transform)
	testing.expect(t, reused_transform.position == [3]f32{55, 66, 0}, "a recycled entity index in another World remains unrelated")
	edited := replica.entities[0]
	assert(ecs.set(&world, edited, Identity{500, 999}))
	next.tick = 4
	testing.expect(t, apply_snapshot(&replica, &world, &registry, next) && replica.entities[0] != edited)
	identity, _ := ecs.get(&world, edited, Identity)
	testing.expect(t, identity.owner_peer == 999 && ecs.is_alive(&world, edited), "an application Identity edit relinquishes replica ownership")
	clear(&replica, &world)
	testing.expect(t, ecs.is_alive(&world, reused) && ecs.is_alive(&world, edited) && world.entity_count == 2)
}

@(test)
clear_preserves_application_children :: proc(t: ^testing.T) {
	registry := test_registry(); defer ecs.destroy_registry(&registry)
	world := ecs.init(); defer ecs.destroy(&world)
	replica: Replica
	assert(apply_snapshot(&replica, &world, &registry, Snapshot{tick = 1, count = 1, states = {0 = State{1, 2, {}}}}))
	children: [3]ecs.Entity
	for &child in children {
		child = ecs.create_entity(&world)
		assert(ecs.set_parent(&world, child, replica.entities[0]))
	}
	clear(&replica, &world)
	for child in children {
		parent, has_parent := ecs.get_parent(&world, child)
		testing.expect(t, ecs.is_alive(&world, child) && !has_parent && parent == ecs.Entity(0) && world.entity_count == 3)
	}
}

@(test)
world_snapshot_is_deterministic_and_validated :: proc(t: ^testing.T) {
	registry := test_registry(); defer ecs.destroy_registry(&registry)
	world := ecs.init(); defer ecs.destroy(&world)
	last := test_add_player(&world, &registry, State{30, 2, {3, 4}})
	first := test_add_player(&world, &registry, State{10, 1, {1, 2}})
	_ = test_add_player(&world, &registry, State{20, 1, {2, 3}})
	assert(ecs.set_enabled(&world, last, false))
	value, valid := snapshot_from_world(&world, 123)
	testing.expect(t, valid && value.tick == 123 && value.count == 3 && value.states[0].id == 10 && value.states[1].id == 20 && value.states[2].id == 30)
	assert(ecs.set(&world, first, Identity{30, 1}))
	_, valid = snapshot_from_world(&world, 124)
	testing.expect(t, !valid, "two local entities cannot share a network ID")
	assert(ecs.set(&world, first, Identity{10, 0}))
	_, valid = snapshot_from_world(&world, 124)
	testing.expect(t, !valid)
	assert(ecs.set(&world, first, Identity{10, 1}))
	for index in 0 ..< MAX_ENTITIES-2 {_ = test_add_player(&world, &registry, State{u32(100+index), 1, {}})}
	_, valid = snapshot_from_world(&world, 125)
	testing.expect(t, !valid, "oversized worlds fail instead of silently dropping entities")
}

@(test)
replica_ticks_wrap_and_empty_snapshot_removes_players :: proc(t: ^testing.T) {
	registry := test_registry(); defer ecs.destroy_registry(&registry)
	world := ecs.init(); defer ecs.destroy(&world)
	replica: Replica
	assert(apply_snapshot(&replica, &world, &registry, Snapshot{tick = 0xffffffff, count = 1, states = {0 = State{1, 1, {}}}}))
	testing.expect(t, apply_snapshot(&replica, &world, &registry, Snapshot{tick = 0}) && replica.count == 0 && world.entity_count == 0)
	testing.expect(t, !apply_snapshot(&replica, &world, &registry, Snapshot{tick = 0xffffffff}))
}
