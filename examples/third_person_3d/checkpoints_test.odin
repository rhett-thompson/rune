package main

import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"
import "rune:ecs"
import "rune:save"
import "rune:scene"

@(test)
legacy_course_checkpoint_restores_prefab_entities :: proc(t: ^testing.T) {
	sync.mutex_lock(&interaction_test_lock); defer sync.mutex_unlock(&interaction_test_lock)
	r := ecs.init_registry(); defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r) && register_course_components(&r))
	layers := make(map[string]u8); defer delete(layers)
	layers["Gameplay"] = 1; layers["Player"] = 2
	w, loaded := scene.load_with_layers("examples/third_person_3d/scenes/main.scene.json", &r, layers)
	defer scene.clear_load_error()
	if !testing.expect(t, loaded, scene.last_load_error()) {return}; defer ecs.destroy(&w)
	m, ready := save.init("examples/third_person_3d", {game_id="course-migration-test", game_version=2, migrate=migrate_course_checkpoint})
	defer save.destroy(&m)
	assert(ready && register_course_saves(&m, &r))
	assert(save.begin_scene(&m, &w, "scenes/main.scene.json"))
	crate, _ := ecs.find_entity_by_id(&w, "course/pushable_crate")
	pose, _ := ecs.get_transform(&w, crate)
	pose.position.x += 3; ecs.set_transform(&w, crate, pose)
	wall, _ := ecs.find_entity_by_id(&w, "course/thin_wall")
	ecs.destroy_entity(&w, wall)
	assert(save.capture(&m, &w))

	// Reconstruct the old, unprefixed save layout, including a moved prop and
	// removed obstacle; no filesystem save is needed to exercise restoration.
	a := mem.dynamic_arena_allocator(m.checkpoint.arena)
	state := m.checkpoint.document.scenes["scenes/main.scene.json"]
	legacy := make(map[string]save.Entity_State, a)
	for id, saved_record in state.entities {
		record := saved_record
		if id == "course" {continue}
		if record.parent == "course" {record.parent = ""}
		legacy[strings.trim_prefix(id, "course/")] = record
	}
	state.entities = legacy
	for &id in state.baseline {id = strings.trim_prefix(id, "course/")}
	for &id in state.removed {id = strings.trim_prefix(id, "course/")}
	m.checkpoint.document.scenes["scenes/main.scene.json"] = state
	assert(migrate_course_checkpoint(&m.checkpoint.document, 1, 2, a))
	restored, ok := save.prepare_scene(&m, &m.checkpoint, "scenes/main.scene.json", &r, layers)
	if !testing.expect(t, ok, save.last_error(&m)) {return}; defer ecs.destroy(&restored)
	saved_crate, _ := ecs.find_entity_by_id(&restored, "course/pushable_crate")
	saved_pose, _ := ecs.get_transform(&restored, saved_crate)
	parent, _ := ecs.get_parent(&restored, saved_crate)
	root, _ := ecs.find_entity_by_id(&restored, "course")
	testing.expect(t, saved_pose == pose && parent == root, "saved obstacle pose survives under the identity parent")
	_, wall_exists := ecs.find_entity_by_id(&restored, "course/thin_wall")
	testing.expect(t, !wall_exists, "removed obstacles keep their migrated IDs")
}
