package main

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import rune "rune:core"
import "rune:ecs"
import "rune:save"
import "rune:scene"

Health :: struct {current: int}
Inventory :: struct {items: []string}
Link :: struct {target: ecs.Entity_Ref}
Timer :: struct {remaining: f32}
Runtime_Timer :: struct {elapsed: f32}
Unsafe_Handle :: struct {target: ecs.Entity}
Unsafe_Pointer :: struct {value: ^int}
Tree :: struct {children: []Tree}
starts, restores, shutdowns: int

timer_capture :: proc(world: ^ecs.World, entity: ecs.Entity, a: mem.Allocator) -> (json.Value, bool) {
	value, ok := ecs.get(world, entity, Timer)
	if !ok {return {}, false}
	runtime, found := ecs.resource(world, Runtime_Timer)
	if found {value.remaining -= runtime.elapsed}
	return ecs.runtime_json(value, a)
}
timer_restore :: proc(world: ^ecs.World, entity: ecs.Entity, value: json.Value) -> bool {
	component: Timer
	bytes, err := json.marshal(value, allocator = context.temp_allocator)
	if err != nil || json.unmarshal(bytes, &component, allocator = context.temp_allocator) != nil || component.remaining < 0 {return false}
	return ecs.set(world, entity, component)
}
prepare :: proc(world: ^ecs.World, document: ^save.Document) -> bool {
	for entity in ecs.entities_with_component(world, "Link", include_disabled = true) {
		link, _ := ecs.get(world, entity, Link)
		if _, exists := ecs.resolve_entity_ref(world, link.target); !exists {return false}
	}
	return true
}
migrate :: proc(document: ^save.Document, from, to: int, a: mem.Allocator) -> bool {
	if from != 1 || to != 2 {return false}
	document.globals = json.String(strings.clone("migrated", a) or_else "")
	return true
}
start :: proc(game: ^rune.Engine, world: ^ecs.World) {starts += 1}
restored :: proc(game: ^rune.Engine, world: ^ecs.World) {restores += 1}
stopped :: proc(game: ^rune.Engine, world: ^ecs.World) {shutdowns += 1}
entity :: proc(world: ^ecs.World, id: string) -> ecs.Entity {
	result, found := ecs.find_entity_by_id(world, id)
	assert(found)
	return result
}
check :: proc(ok: bool, manager: ^save.Manager) {if !ok {fmt.eprintln(save.last_error(manager))}; assert(ok)}

main :: proc() {
	// All writable fixtures stay under the repository's ignored build directory.
	assert(os.make_directory_all("build/save-validation") == nil)
	game: rune.Engine
	game.project_directory, _ = filepath.abs("tools/save_validation/fixtures")
	defer delete(game.project_directory)
	game.registry = ecs.init_registry()
	defer ecs.destroy_registry(&game.registry)
	assert(ecs.register_builtin_components(&game.registry))
	assert(ecs.register_component(&game.registry, "Health", Health, Health{100}, "Health"))
	assert(ecs.register_component(&game.registry, "Inventory", Inventory, Inventory{}, "Inventory"))
	assert(ecs.register_component(&game.registry, "Link", Link, Link{}, "Stable reference"))
	assert(ecs.register_component(&game.registry, "Timer", Timer, Timer{10}, "Timer"))
	assert(ecs.register_component(&game.registry, "Tree", Tree, Tree{}, "Recursive JSON data"))
	assert(ecs.register_component(&game.registry, "UnsafeHandle", Unsafe_Handle, Unsafe_Handle{}, "Handle"))
	assert(!ecs.register_component(&game.registry, "UnsafePointer", Unsafe_Pointer, Unsafe_Pointer{}, "Pointer"))
	assert(rune.configure_saves(&game, save.Options{game_id = "rune-validation", game_version = 1,
		directory = "build/save-validation", prepare = prepare}))
	defer save.destroy(&game.saves)
	assert(!save.register_component(&game.saves, &game.registry, Unsafe_Handle))
	assert(!save.register_component(&game.saves, &game.registry, Unsafe_Pointer))
	check(save.register_component(&game.saves, &game.registry, ecs.Transform), &game.saves)
	check(save.register_component(&game.saves, &game.registry, Tree), &game.saves)
	check(save.register_component(&game.saves, &game.registry, Health), &game.saves)
	check(save.register_component(&game.saves, &game.registry, Inventory), &game.saves)
	check(save.register_component(&game.saves, &game.registry, Link), &game.saves)
	check(save.register_component(&game.saves, &game.registry, Timer, save.Adapter{timer_capture, timer_restore}), &game.saves)
	game.scene_watches = make(map[string]map[string]i64)
	defer {
		for path, watch in game.scene_watches {rune.destroy_scene_watch(watch); delete(path)}
		delete(game.scene_watches)
	}
	assert(rune.load_active_scene(&game, "main.scene.json"))
	defer ecs.destroy(&game.active_world)
	game.fixed_delta_time = 1.0 / 60.0
	game.systems = make([dynamic]rune.System)
	defer delete(game.systems)
	assert(rune.register_system(&game, rune.System{name="lifecycle", start=start, on_save_restored=restored, shutdown=stopped}))
	game.scene_loop_active = true
	rune.run_start_systems(&game, &game.active_world)
	world := &game.active_world
	old_player := entity(world, "player")
	assert(ecs.set(world, old_player, Health{75}))
	transform, _ := ecs.get(world, old_player, ecs.Transform)
	transform.position = {12, 0, 8}
	assert(ecs.set(world, old_player, transform))
	assert(ecs.add_resource(world, Runtime_Timer{3}))
	assert(ecs.set_parent(world, entity(world,"guard_child"), old_player))
	assert(ecs.destroy_entity(world, entity(world,"guard")))
	assert(ecs.remove_component(world, entity(world,"door"), "Health"))
	drop := ecs.create_entity(world)
	assert(ecs.set_entity_metadata(world, drop, "drop_1", "Dropped item", "loot", 1))
	assert(ecs.add_component(world, &game.registry, drop, "Transform", json.Object{}))
	assert(ecs.add_component(world, &game.registry, drop, "Inventory", json.Object{}))
	assert(ecs.set(world, drop, Inventory{[]string{"potion", "coin"}}))
	assert(ecs.set_parent(world, drop, old_player))
	check(save.track_spawn(&game.saves, world, drop), &game.saves)
	check(save.set_globals(&game.saves, json.String("quest complete")), &game.saves)
	check(rune.request_save(&game,"checkpoint"), &game.saves)
	assert(!rune.request_load(&game,"checkpoint")) // Pending requests cannot overwrite each other.
	rune.process_save_requests(&game)
	check(game.save_result.ok, &game.saves)
	assert(game.save_result.sequence == 1 && starts == 1 && restores == 0)
	assert(ecs.set(world, old_player, Health{1}))
	assert(ecs.destroy_entity(world, drop))
	check(rune.request_load(&game,"checkpoint"), &game.saves)
	assert(ecs.is_alive(world,old_player)) // Accepted requests are deferred.
	rune.process_save_requests(&game)
	check(game.save_result.ok, &game.saves)
	assert(!ecs.is_alive(world,old_player) && starts == 1 && restores == 1 && shutdowns == 1)
	player := entity(world,"player")
	hp, _ := ecs.get(world, player, Health)
	assert(hp.current == 75)
	transform, _ = ecs.get(world, player, ecs.Transform)
	assert(transform.position == [3]f32{12,0,8})
	timer, _ := ecs.get(world, player, Timer)
	assert(timer.remaining == 7)
	assert(!ecs.has_component_data(world,entity(world,"door"),"Health"))
	assert(!ecs.is_enabled(world,entity(world,"hidden")))
	assert((ecs.get_parent(world,entity(world,"guard_child")) or_else ecs.Entity(0)) == player)
	assert((ecs.get_parent(world,entity(world,"drop_1")) or_else ecs.Entity(0)) == player)
	items, _ := ecs.get(world,entity(world,"drop_1"),Inventory)
	assert(len(items.items) == 2 && items.items[0] == "potion")
	assert(save.globals(&game.saves).(json.String) == "quest complete")
	// Neither a missing scene nor an adapter/prepare failure can replace a live world.
	safe_player := player
	assert(rune.change_scene(&game,"missing.scene.json")); rune.process_save_requests(&game)
	assert(!game.save_result.ok && ecs.is_alive(world,safe_player))
	assert(rune.change_scene(&game,"../outside.scene.json")); rune.process_save_requests(&game)
	assert(!game.save_result.ok && ecs.is_alive(world,safe_player))
	// A -> B -> A retains removals, spawned objects, and component state.
	assert(rune.change_scene(&game,"other.scene.json"))
	rune.process_save_requests(&game)
	check(game.save_result.ok,&game.saves)
	assert(starts == 2 && restores == 1)
	assert(ecs.set(world,entity(world,"other"),Health{9}))
	assert(rune.change_scene(&game,"main.scene.json"))
	rune.process_save_requests(&game)
	check(game.save_result.ok,&game.saves)
	assert(starts == 2 && restores == 2)
	assert((ecs.get(world,entity(world,"player"),Health) or_else Health{}).current == 75)
	// An I/O failure must preserve the primary bytes.
	primary, _ := save.slot_path(&game.saves,"checkpoint")
	original, read_error := os.read_entire_file(primary,context.temp_allocator)
	assert(read_error == nil)
	assert(os.make_directory(fmt.tprintf("%s.tmp",primary)) == nil)
	assert(!save.write_slot(&game.saves,"checkpoint"))
	unchanged, read_again := os.read_entire_file(primary,context.temp_allocator)
	assert(read_again == nil && string(unchanged) == string(original))
	entity(world,"drop_1")
	// Save twice: the prior checkpoint remains recoverable as a backup.
	assert(rune.request_save(&game,"checkpoint")); rune.process_save_requests(&game)
	check(game.save_result.ok,&game.saves)
	assert(ecs.set(world,entity(world,"player"),Health{44}))
	assert(rune.request_save(&game,"checkpoint")); rune.process_save_requests(&game)
	check(game.save_result.ok,&game.saves)
	assert(rune.request_load(&game,"checkpoint",backup=true)); rune.process_save_requests(&game)
	check(game.save_result.ok,&game.saves)
	assert((ecs.get(world,entity(world,"player"),Health) or_else Health{}).current == 75)
	// Bad data never runs shutdown/restore callbacks or changes the active world.
	stable := entity(world,"player")
	previous_shutdowns := shutdowns
	assert(os.write_entire_file("build/save-validation/broken.save.json", "{broken") == nil)
	assert(rune.request_load(&game,"broken")); rune.process_save_requests(&game)
	assert(!game.save_result.ok && ecs.is_alive(world,stable) && shutdowns == previous_shutdowns)
	assert(!rune.request_save(&game,"../escape"))
	bad, copied := save.clone_checkpoint(&game.saves.checkpoint)
	assert(copied)
	defer save.destroy_checkpoint(&bad)
	bad_player := bad.document.scenes[bad.document.active_scene].entities["player"]
	bad_player.parent = "missing"
	bad_entities := bad.document.scenes[bad.document.active_scene].entities
	bad_entities["player"] = bad_player
	write_document("build/save-validation/invalid.save.json", &bad)
	assert(rune.request_load(&game,"invalid")); rune.process_save_requests(&game)
	assert(!game.save_result.ok && ecs.is_alive(world,stable) && shutdowns == previous_shutdowns)
	bad_player.parent = ""
	bad_entities["player"] = bad_player
	// A missing stable reference is rejected by the game prepare callback.
	link_json: json.Value
	assert(json.unmarshal(transmute([]u8)string(`{"target":{"id":"missing"}}`), &link_json, allocator=save.allocator(&bad)) == nil)
	bad_components := bad_player.components
	bad_components["Link"] = link_json
	write_document("build/save-validation/invalid.save.json", &bad)
	assert(rune.request_load(&game,"invalid")); rune.process_save_requests(&game)
	assert(!game.save_result.ok && ecs.is_alive(world,stable) && shutdowns == previous_shutdowns)
	// An incompatible version is rejected; an explicit migration is accepted.
	game.saves.options.game_version = 2
	assert(rune.request_load(&game,"checkpoint")); rune.process_save_requests(&game)
	assert(!game.save_result.ok && ecs.is_alive(world,stable))
	game.saves.options.migrate = migrate
	assert(rune.request_load(&game,"checkpoint")); rune.process_save_requests(&game)
	check(game.save_result.ok,&game.saves)
	assert(save.globals(&game.saves).(json.String) == "migrated")
	assert(rune.change_scene(&game,"other.scene.json")); rune.process_save_requests(&game)
	check(game.save_result.ok,&game.saves)
	assert((ecs.get(world,entity(world,"other"),Health) or_else Health{}).current == 9)
	fmt.println("Save validation passed: slots, backup, deferred lifecycle, globals, adapters, hierarchy, spawns, removals, multi-scene progress, invalid data, migration")
	for argument in os.args[1:] {if argument == "--runtime" {validate_runtime()}}
}

write_document :: proc(path: string, checkpoint: ^save.Checkpoint) {
	bytes, err := json.marshal(checkpoint.document, allocator = context.temp_allocator)
	assert(err == nil && os.write_entire_file(path,bytes) == nil)
}
