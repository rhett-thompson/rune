package main

import "core:os"
import "rune:assets"
import "rune:ecs"
import bridge "rune:r3d_bridge"
import r3d "r3d:r3d"
import rl "vendor:raylib"

validate_external_clips :: proc(ctx: ^bridge.Context, world: ^ecs.World, manager: ^assets.Asset_Manager) {
	path :: "../../build/punch-validation.fbx"
	output :: "build/punch-validation.fbx"
	source, error := os.read_entire_file("examples/assets/Punching.fbx", context.allocator)
	assert(error == nil)
	defer delete(source)
	assert(os.write_entire_file(output, source) == nil)
	defer os.remove(output)
	entity, _ := ecs.find_entity_by_id(world, "strut")
	assert(bridge.register_model_animation_source(ctx, Strut, "punch", path))
	assert(bridge.register_model_animation_source(ctx, Strut, "punch", path))
	assert(len(ctx.animation_sources) == 1, "scene start can register the same source repeatedly")
	bridge.update_animations(ctx, world, manager, 0)
	library := ctx.models[Strut].animations
	assert(library.count == 2 && r3d.GetAnimationIndex(library, "punch") == 1)
	punch := ([^]r3d.Animation)(library.animations)[1]
	assert(punch.channelCount == 52 && punch.boneCount == 52, "skinless clip is mapped onto mesh joints")
	assert(near(punch.duration / punch.ticksPerSecond, 38.0 / 30.0))
	player, ready := bridge.animation_player(ctx, entity)
	assert(ready)
	walk_pose := make([]rl.Matrix, player.skeleton.boneCount)
	defer delete(walk_pose)
	copy(walk_pose, player.localPose[:len(walk_pose)])
	animator, _ := ecs.get_model_animator(world, entity)
	animator.loop = false
	assert(ecs.set_model_animator(world, entity, animator))
	assert(ecs.transition_model_animation(world, entity, "punch", 0.12))
	bridge.update_animations(ctx, world, manager, 0.4)
	player, ready = bridge.animation_player(ctx, entity)
	assert(ready && near(state(world, entity).elapsed, 0.4))
	changed := 0
	for previous, i in walk_pose {if previous != player.localPose[i] {changed += 1}}
	assert(changed > 20, "punch produces a different full-body pose on the walking mesh")
	assert(ecs.play_model_animation(world, entity, "punch"))
	bridge.update_animations(ctx, world, manager, 0.05)
	assert(near(state(world, entity).elapsed, 0.05), "repeat presses restart the punch")
	force_revision(manager, path)
	bridge.update_animations(ctx, world, manager, 0)
	assert(near(state(world, entity).elapsed, 0.05) && ctx.models[Strut].animations.count == 2,
	       "animation-only reload preserves time and aliases")
	force_revision(manager, Strut)
	bridge.update_animations(ctx, world, manager, 0)
	assert(near(state(world, entity).elapsed, 0.05) && ctx.models[Strut].animations.count == 2,
	       "model reload reattaches its external animations")
	player, ready = bridge.animation_player(ctx, entity)
	assert(ready)
	assert(os.write_entire_file(output, "not an FBX") == nil)
	force_revision(manager, path)
	bridge.update_animations(ctx, world, manager, 0)
	assert(ctx.animation_players[entity].player.skinTexture == player.skinTexture,
	       "failed clip reload keeps the working library and player")
	assert(os.write_entire_file(output, source) == nil)
	force_revision(manager, path)
	bridge.update_animations(ctx, world, manager, 0)
	assert(ctx.models[Strut].animations.count == 2 && near(state(world, entity).elapsed, 0.05))
	bridge.update_animations(ctx, world, manager, 2)
	assert(state(world, entity).finished && !state(world, entity).playing, "punch plays once")
	animator, _ = ecs.get_model_animator(world, entity)
	animator.loop = true
	assert(ecs.set_model_animator(world, entity, animator))
	assert(ecs.transition_model_animation(world, entity, "mixamo.com", 0.18))
	bridge.update_animations(ctx, world, manager, 0.2)
	assert(state(world, entity).playing && !state(world, entity).finished)
	assert(len(ctx.animation_players[entity].blend_pose) == 0, "return-to-walk blend completes")

	// Matching counts alone must never allow an unrelated rig to be animated.
	unrelated := ctx.models[Model].model.skeleton
	extra: r3d.AnimationLib
	assert(!bridge.append_imported_animation(&extra, "examples/assets/Punching.fbx", &unrelated, "punch"))
	assert(extra.count == 0 && extra.animations == nil)
}
