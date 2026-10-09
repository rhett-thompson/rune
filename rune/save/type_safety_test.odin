package save

import "core:encoding/json"
import "core:testing"
import "rune:ecs"

Test_Kind :: enum u8 { Theft, Stolen_Sale }
Test_Memory :: struct {
	kind: Test_Kind,
	time: f64,
	location, culprit: [3]f32,
}
// Distinct sibling types fill the visited table while recursion returns to the
// parent. A long chain alone can miss the stale map-header regression.
Test_Brain :: struct {
	state: int,
	suspicion: f32,
	last_known: [3]f32,
	waypoint: i32,
	noticed, seen, confronted: bool,
	memory: Test_Memory,
	has_memory: bool,
}
Test_Brain_Array :: struct {
	state: int,
	suspicion: f32,
	last_known: [3]f32,
	waypoint: i32,
	noticed: bool,
	memories: [2]Test_Memory,
}
Test_Unsafe_Handle :: struct {target: ecs.Entity}
Test_Unsafe_Pointer :: struct {value: ^int}
Test_Excluded_Runtime :: struct {
	brain: Test_Brain,
	target: ecs.Entity `json:"-"`,
	pointer: ^int `json:"-"`,
}
Test_Tree :: struct {value: int, children: []Test_Tree}

@(test)
automatic_persistence_shares_visited_types_and_restores_spawns :: proc(t: ^testing.T) {
	// Keep all ECS world creation in one test because generation state is shared.
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	testing.expect(t, ecs.register_component(&registry, "Brain", Test_Brain, Test_Brain{}))
	testing.expect(t, ecs.register_component(&registry, "BrainArray", Test_Brain_Array, Test_Brain_Array{}))
	testing.expect(t, ecs.register_component(&registry, "UnsafeHandle", Test_Unsafe_Handle, Test_Unsafe_Handle{}))
	// A descriptor lets save's pointer check run independently of ECS JSON defaults.
	testing.expect(t, ecs.register_component(&registry, ecs.Component_Descriptor{
		name = "UnsafePointer", type_id = typeid_of(Test_Unsafe_Pointer),
	}))
	testing.expect(t, ecs.register_component(&registry, "ExcludedRuntime", Test_Excluded_Runtime, Test_Excluded_Runtime{}))
	testing.expect(t, ecs.register_component(&registry, "Tree", Test_Tree, Test_Tree{}))
	options := Options{game_id = "type-safety-test", game_version = 1, directory = "build/save-type-safety-test"}
	registered, initialized := init(".", options)
	testing.expect(t, initialized)
	defer destroy(&registered)
	if !initialized {return}
	testing.expect(t, register_component(&registered, &registry, Test_Brain), last_error(&registered))
	testing.expect(t, register_component(&registered, &registry, Test_Brain_Array), last_error(&registered))
	testing.expect(t, !register_component(&registered, &registry, Test_Unsafe_Handle), "runtime entity handles require an adapter")
	testing.expect(t, !register_component(&registered, &registry, Test_Unsafe_Pointer), "native pointers require an adapter")
	testing.expect(t, register_component(&registered, &registry, Test_Excluded_Runtime), last_error(&registered))
	testing.expect(t, register_component(&registered, &registry, Test_Tree), "recursive JSON slices terminate the type walk")

	// No policies are registered here: tracked spawns exercise capture's own walk.
	manager, spawn_initialized := init(".", options)
	testing.expect(t, spawn_initialized)
	defer destroy(&manager)
	if !spawn_initialized {return}
	world := ecs.init()
	defer ecs.destroy(&world)
	testing.expect(t, begin_scene(&manager, &world, "empty.scene.json"), last_error(&manager))
	spawn := ecs.create_entity(&world)
	testing.expect(t, ecs.set_entity_metadata(&world, spawn, "brain", "Brain", "saved", 1))
	memory := Test_Memory{.Stolen_Sale, 12.5, {1, 2, 3}, {4, 5, 6}}
	brain := Test_Brain{3, 0.75, {7, 8, 9}, 4, true, false, true, memory, true}
	array := Test_Brain_Array{5, 0.5, {10, 11, 12}, 6, true,
		{memory, Test_Memory{.Theft, 25, {13, 14, 15}, {16, 17, 18}}}}
	leaves := [2]Test_Tree{{value = 3}, {value = 4}}
	branches := [1]Test_Tree{{value = 2, children = leaves[:]}}
	tree := Test_Tree{value = 1, children = branches[:]}
	runtime_value := 42
	testing.expect(t, ecs.add(&world, &registry, spawn, brain))
	testing.expect(t, ecs.add(&world, &registry, spawn, array))
	testing.expect(t, ecs.add(&world, &registry, spawn, tree))
	testing.expect(t, ecs.add(&world, &registry, spawn,
		Test_Excluded_Runtime{brain = brain, target = spawn, pointer = &runtime_value}))
	testing.expect(t, track_spawn(&manager, &world, spawn), last_error(&manager))
	captured := capture(&manager, &world)
	testing.expect(t, captured, last_error(&manager))
	if !captured {return}
	testing.expect(t, len(manager.policies) == 0, "spawn reconstruction includes components without save policies")

	// Exercise the persisted JSON representation without writing a save file.
	checkpoint := new_checkpoint()
	defer destroy_checkpoint(&checkpoint)
	bytes, marshal_error := json.marshal(manager.checkpoint.document, allocator = context.temp_allocator)
	testing.expect(t, marshal_error == nil)
	if marshal_error != nil {return}
	unmarshal_error := json.unmarshal(bytes, &checkpoint.document, allocator = allocator(&checkpoint))
	testing.expect(t, unmarshal_error == nil)
	if unmarshal_error != nil {return}
	restored := ecs.init()
	defer ecs.destroy(&restored)
	state := checkpoint.document.scenes[checkpoint.document.active_scene]
	applied := apply_state(&manager, &restored, &registry, state)
	testing.expect(t, applied, last_error(&manager))
	if !applied {return}
	entity, found := ecs.find_entity_by_id(&restored, "brain")
	testing.expect(t, found)
	if !found {return}
	restored_brain, brain_found := ecs.get(&restored, entity, Test_Brain)
	restored_array, array_found := ecs.get(&restored, entity, Test_Brain_Array)
	testing.expect(t, brain_found && restored_brain == brain, "nested structs restore every value")
	testing.expect(t, array_found && restored_array == array, "fixed arrays restore every element")
	excluded, excluded_found := ecs.get(&restored, entity, Test_Excluded_Runtime)
	testing.expect(t, excluded_found && excluded.brain == brain && excluded.target == 0 && excluded.pointer == nil,
		"JSON exclusions keep runtime handles and pointers out of the checkpoint")
	restored_tree, tree_found := ecs.get(&restored, entity, Test_Tree)
	testing.expect(t, tree_found && restored_tree.value == 1 && len(restored_tree.children) == 1)
	if tree_found && len(restored_tree.children) == 1 {
		branch := restored_tree.children[0]
		testing.expect(t, branch.value == 2 && len(branch.children) == 2)
		if len(branch.children) == 2 {
			testing.expect(t, branch.children[0].value == 3 && branch.children[1].value == 4)
		}
	}

	testing.expect(t, ecs.add(&world, &registry, spawn, Test_Unsafe_Handle{target = spawn}))
	testing.expect(t, !capture(&manager, &world), "unregistered spawned handles also require an adapter")
}
