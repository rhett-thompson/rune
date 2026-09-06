package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "rune:assets"
import "rune:ecs"
import bridge "rune:r3d_bridge"
import "rune:scene"
import rl "vendor:raylib"
import r3d "r3d:r3d"

Root :: "examples/skeletal_animation_3d"
Scene :: Root + "/scenes/main.scene.json"
Model :: "assets/arm.gltf"

parse :: proc(text: string) -> json.Value {
	value: json.Value
	assert(json.unmarshal(transmute([]u8)text, &value, allocator = context.temp_allocator) == nil)
	return value
}

near :: proc(a, b: f32) -> bool {return math.abs(a - b) < 0.002}

state :: proc(world: ^ecs.World, entity: ecs.Entity) -> ecs.Model_Animation_State {
	value, found := ecs.get_model_animation_state(world, entity)
	assert(found)
	return value
}

load :: proc(registry: ^ecs.Component_Registry) -> ecs.World {
	world, ok := scene.load(Scene, registry)
	assert(ok, scene.last_load_error())
	return world
}

validate_components :: proc(registry: ^ecs.Component_Registry) {
	world := load(registry)
	defer ecs.destroy(&world)
	left, _ := ecs.find_entity_by_id(&world, "left")
	animator, ok := ecs.get(&world, left, ecs.ModelAnimator)
	assert(
		ok && animator.clip == "bend" && animator.speed == 1 && animator.loop && animator.autoplay,
	)
	assert(ecs.play_model_animation(&world, left, "sway"))
	assert(ecs.pause_model_animation(&world, left) && !state(&world, left).playing)
	assert(ecs.seek_model_animation(&world, left, 0.5))
	assert(ecs.resume_model_animation(&world, left) && state(&world, left).playing)
	version := ecs.change_version(&world)
	assert(!ecs.set_runtime_field(&world, registry, left, "ModelAnimator", "speed", parse("0")))
	assert(!ecs.set_runtime_field(&world, registry, left, "ModelAnimator", "loop", parse("17")))
	assert(ecs.change_version(&world) == version)
	assert(ecs.set_runtime_field(&world, registry, left, "ModelAnimator", "speed", parse("2")))
	assert(near(state(&world, left).elapsed, 0.5), "speed edits preserve playback")
	snapshot, found := ecs.runtime_component_json(&world, left, "ModelAnimator")
	assert(found)
	object := snapshot.(json.Object)
	assert(object["speed"].(json.Float) == 2 && object["clip"].(json.String) == "sway")
	assert(ecs.stop_model_animation(&world, left) && state(&world, left).elapsed == 0)
	assert(
		ecs.set_runtime_field(&world, registry, left, "ModelAnimator", "clip", parse("\"bend\"")),
	)
	assert(!state(&world, left).initialized, "clip changes reset playback")
	copy := load(registry)
	other, _ := ecs.find_entity_by_id(&copy, "left")
	assert(
		ecs.set_runtime_field(&copy, registry, other, "ModelAnimator", "clip", parse("\"sway\"")),
	)
	assert(ecs.apply_value_snapshot(&world, &copy))
	ecs.destroy(&copy)
	animator, ok = ecs.get(&world, left, ecs.ModelAnimator)
	assert(ok && animator.clip == "sway", "snapshot strings survive donor destruction")
	assert(ecs.remove_component(&world, left, "ModelAnimator"))
	_, found = ecs.get_model_animation_state(&world, left)
	assert(!found && !ecs.play_model_animation(&world, left, "bend"))
}

validate_runtime :: proc(registry: ^ecs.Component_Registry) {
	rl.SetTraceLogLevel(.WARNING)
	rl.SetConfigFlags({.WINDOW_HIDDEN,.WINDOW_HIGHDPI,.WINDOW_RESIZABLE})
	rl.InitWindow(640, 480, "Rune animation validation")
	defer rl.CloseWindow()
	ctx, ok := bridge.init(Root, 640, 480)
	assert(ok)
	manager := assets.init(Root)
	defer assets.shutdown(&manager)
	defer bridge.shutdown(&ctx)
	world := load(registry)
	defer ecs.destroy(&world)
	left, _ := ecs.find_entity_by_id(&world, "left")
	middle, _ := ecs.find_entity_by_id(&world, "middle")
	names := bridge.animation_clips(&ctx, &manager, Model)
	assert(len(names) == 2 && names[0] == "bend" && names[1] == "sway")
	bridge.update_animations(&ctx, &world, &manager, 0.5)
	assert(near(state(&world, left).elapsed, 0.5))
	assert(near(state(&world, middle).elapsed, 0.25), "independent speed")
	player, ready := bridge.animation_player(&ctx, left)
	other, other_ready := bridge.animation_player(&ctx, middle)
	assert(
		ready &&
		other_ready &&
		player.skinTexture != other.skinTexture &&
		player.states != other.states,
	)
	assert(player.animLib.animations == other.animLib.animations, "clip data shared")
	before := state(&world, left)
	for _ in 0 ..< 3 {
		rl.BeginDrawing()
		assert(bridge.draw_scene(&ctx, &world, &manager))
		rl.EndDrawing()
	}
	assert(state(&world, left) == before, "draw never advances or publishes simulation state")
	// The bridge follows physical framebuffer size without changing simulation.
	rl.SetWindowSize(800, 600)
	for _ in 0..<3 {
		rl.BeginDrawing()
		assert(bridge.draw_scene(&ctx, &world, &manager))
		rl.EndDrawing()
	}
	render_width, render_height: i32
	r3d.GetResolution(&render_width, &render_height)
	assert(render_width == rl.GetRenderWidth() && render_height == rl.GetRenderHeight(), "3D targets follow DPI and resize")
	ctx.match_framebuffer = false
	r3d.SetResolution(320, 240)
	rl.BeginDrawing()
	assert(bridge.draw_scene(&ctx, &world, &manager))
	rl.EndDrawing()
	r3d.GetResolution(&render_width, &render_height)
	assert(render_width == 320 && render_height == 240, "fixed internal resolution opt-out")
	ctx.match_framebuffer = true
	assert(state(&world, left) == before, "display changes preserve animation state")
	assert(ecs.pause_model_animation(&world, left))
	bridge.update_animations(&ctx, &world, &manager, 0.25)
	assert(near(state(&world, left).elapsed, 0.5) && !state(&world, left).playing)
	assert(ecs.resume_model_animation(&world, left))
	bridge.update_animations(&ctx, &world, &manager, 0.25)
	assert(near(state(&world, left).elapsed, 0.75))
	assert(ecs.play_model_animation(&world, left, "sway"))
	bridge.update_animations(&ctx, &world, &manager, 0.1)
	assert(near(state(&world, left).elapsed, 0.1))
	assert(ecs.stop_model_animation(&world, left))
	bridge.update_animations(&ctx, &world, &manager, 0.3)
	assert(state(&world, left).elapsed == 0 && !state(&world, left).playing)
	animator, _ := ecs.get_model_animator(&world, left)
	animator.loop = false
	assert(ecs.set(&world, left, animator))
	assert(ecs.play_model_animation(&world, left, "bend"))
	bridge.update_animations(&ctx, &world, &manager, 3)
	assert(
		state(&world, left).finished &&
		!state(&world, left).playing &&
		near(state(&world, left).elapsed, 2),
	)
	rl.BeginDrawing()
	assert(bridge.draw_scene(&ctx, &world, &manager))
	rl.EndDrawing()
	assert(
		near(ctx.animation_players[left].player.states[0].currentTime, 2),
		"draw preserves the exact final pose",
	)
	animator.speed = -1
	assert(ecs.set(&world, left, animator))
	assert(ecs.play_model_animation(&world, left, "bend"))
	bridge.update_animations(&ctx, &world, &manager, 0.25)
	assert(
		near(state(&world, left).elapsed, 1.75) && state(&world, left).playing,
		"reverse playback",
	)
	assert(ecs.play_model_animation(&world, left, "missing"))
	bridge.update_animations(&ctx, &world, &manager, 0.1)
	_, ready = bridge.animation_player(&ctx, left)
	assert(!ready, "unknown clips fall back without an invalid native index")
	assert(ecs.play_model_animation(&world, left, "bend"))
	bridge.update_animations(&ctx, &world, &manager, 0)
	_, ready = bridge.animation_player(&ctx, left)
	assert(ready)
	validate_reload(&ctx, &manager, &world)
	validate_failed_reload(&ctx, &manager, &world, left)
	assert(ecs.destroy_entity(&world, middle))
	bridge.update_animations(&ctx, &world, &manager, 0)
	assert(len(ctx.animation_players) == 2)
	assert(ecs.remove_component(&world, left, "ModelAnimator"))
	bridge.update_animations(&ctx, &world, &manager, 0)
	assert(len(ctx.animation_players) == 1)
	old_generation := world.generation
	ecs.destroy(&world)
	world = load(registry)
	bridge.update_animations(&ctx, &world, &manager, 0)
	assert(world.generation != old_generation && len(ctx.animation_players) == 3)
	left, _ = ecs.find_entity_by_id(&world,"left")
	validate_transitions(&ctx,&world,&manager,left)
}

validate_transitions :: proc(ctx: ^bridge.Context, world: ^ecs.World, manager: ^assets.Asset_Manager, entity: ecs.Entity) {
	assert(ecs.play_model_animation(world,entity,"bend"))
	bridge.update_animations(ctx,world,manager,0.5)
	player := ctx.animation_players[entity].player
	pose := make([]rl.Matrix,player.skeleton.boneCount)
	defer delete(pose)
	copy(pose,player.localPose[:len(pose)])
	assert(ecs.transition_model_animation(world,entity,"sway",0.4))
	bridge.update_animations(ctx,world,manager,0)
	for m,i in pose {assert(m==player.localPose[i],"transition starts at previous displayed pose")}
	bridge.update_animations(ctx,world,manager,0.2)
	assert(near(ctx.animation_players[entity].blend_elapsed,0.2))
	copy(pose,player.localPose[:len(pose)])
	assert(ecs.pause_model_animation(world,entity))
	bridge.update_animations(ctx,world,manager,1)
	for m,i in pose {assert(m==player.localPose[i],"pause freezes transition pose")}
	assert(near(ctx.animation_players[entity].blend_elapsed,0.2))
	assert(ecs.resume_model_animation(world,entity))
	bridge.update_animations(ctx,world,manager,0.3)
	assert(len(ctx.animation_players[entity].blend_pose)==0,"completed blend storage released")
	assert(ecs.transition_model_animation(world,entity,"bend",0.5))
	bridge.update_animations(ctx,world,manager,0.1)
	copy(pose,player.localPose[:len(pose)])
	assert(ecs.transition_model_animation(world,entity,"sway",0.4))
	bridge.update_animations(ctx,world,manager,0)
	for m,i in pose {assert(m==player.localPose[i],"interrupted transition stays continuous")}
	assert(!ecs.transition_model_animation(world,entity,"bend",-1))
	assert(ecs.transition_model_animation(world,entity,"bend",0))
	bridge.update_animations(ctx,world,manager,0)
	assert(len(ctx.animation_players[entity].blend_pose)==0,"zero duration switches immediately")
}

validate_reload :: proc(ctx: ^bridge.Context, manager: ^assets.Asset_Manager, world: ^ecs.World) {
	// Bump the same revision consumed by timestamp polling, without touching
	// the user's example file. This exercises replacement and ownership order.
	asset := manager.models[Model]
	asset.revision += 1
	manager.models[Model] = asset
	bridge.update_animations(ctx, world, manager, 0)
	assert(len(ctx.animation_players) == 3 && ctx.models[Model].revision == asset.revision)
	for _, cached in ctx.animation_players {
		assert(cached.player.skeleton.bones == ctx.models[Model].model.skeleton.bones)
		assert(cached.player.animLib.animations == ctx.models[Model].animations.animations)
	}
}

force_revision :: proc(manager: ^assets.Asset_Manager, path: string) {
	asset := manager.models[path]
	asset.revision += 1
	manager.models[path] = asset
}

validate_failed_reload :: proc(
	ctx: ^bridge.Context,
	manager: ^assets.Asset_Manager,
	world: ^ecs.World,
	entity: ecs.Entity,
) {
	output :: "build/model-animation-validation.gltf"
	path :: "../../build/model-animation-validation.gltf"
	source, read_error := os.read_entire_file(Root + "/" + Model, context.temp_allocator)
	assert(read_error == nil)
	assert(os.write_entire_file(output, source) == nil)
	defer os.remove(output)
	renderer, _ := ecs.get_model_renderer(world, entity)
	renderer.model = path
	assert(ecs.set_model_renderer(world, entity, renderer))
	bridge.update_animations(ctx, world, manager, 0)
	previous := ctx.animation_players[entity]
	assert(previous.ready)
	// A valid model with no animation clips must not replace an animated asset.
	value := parse(string(source))
	object := value.(json.Object)
	delete_key(&object, "animations")
	value = object
	bytes, marshal_error := json.marshal(value, allocator = context.temp_allocator)
	assert(marshal_error == nil && os.write_entire_file(output, bytes) == nil)
	force_revision(manager, path)
	bridge.update_animations(ctx, world, manager, 0)
	assert(ctx.animation_players[entity].player.skinTexture == previous.player.skinTexture)
	assert(ctx.models[path].model.skeleton.bones == previous.player.skeleton.bones)
	assert(os.write_entire_file(output, source) == nil)
	force_revision(manager, path)
	bridge.update_animations(ctx, world, manager, 0)
	assert(ctx.animation_players[entity].ready)
	assert(
		ctx.animation_players[entity].player.skeleton.bones ==
		ctx.models[path].model.skeleton.bones,
	)
}

main :: proc() {
	a := rl.MatrixTranslate(0,2,0)
	b := rl.MatrixTranslate(10,4,0)*rl.MatrixRotateZ(math.PI/2)
	middle := bridge.blend_local_pose(a,b,0.5)
	assert(near(middle[0,3],5) && near(middle[1,3],3))
	assert(near(middle[0,0],f32(math.sqrt(0.5))) && near(middle[1,0],f32(math.sqrt(0.5))),"rotation slerp preserves length")
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	validate_components(&registry)
	if len(os.args) > 1 && os.args[1] == "--runtime" {validate_runtime(&registry)}
	fmt.println("Model animation validation passed")
}
