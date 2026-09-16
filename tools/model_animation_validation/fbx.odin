package main

import "core:os"
import "rune:assets"
import "rune:ecs"
import bridge "rune:r3d_bridge"
import r3d "r3d:r3d"

Strut :: "../assets/Strut Walking.fbx"

validate_fbx_importer :: proc(ctx: ^bridge.Context, world: ^ecs.World, manager: ^assets.Asset_Manager, entity: ecs.Entity) {
	source, error := os.read_entire_file(Root + "/" + Strut, context.allocator)
	assert(error == nil)
	defer delete(source)
	file_model := ctx.models[Strut].model
	file_library := ctx.models[Strut].animations
	assert(file_library.count == 1 && file_library.animations.channelCount == 52,
	       "FBX keeps all 52 joint channels instead of dropping pivot animations")
	assert(ecs.seek_model_animation(world, entity, 0.25))
	bridge.update_animations(ctx, world, manager, 0)
	file_player, ready := bridge.animation_player(ctx, entity)
	assert(ready)

	import_flags := [?]r3d.ImportFlags{{}, {.QUALITY}}
	for flags in import_flags {
		importer := bridge.load_importer_from_memory(raw_data(source), u32(len(source)), "fbx", flags)
		assert(importer != nil)
		model := r3d.LoadModelFromImporter(importer)
		library := r3d.LoadAnimationLibFromImporter(importer)
		bridge.unload_importer(importer)
		defer r3d.UnloadModel(model, true)
		defer r3d.UnloadAnimationLib(library)
		assert(model.meshCount == file_model.meshCount && model.skeleton.boneCount == file_model.skeleton.boneCount)
		assert(library.count == 1 && library.animations.channelCount == file_library.animations.channelCount,
		       "memory import uses the same pivot policy, including quality mode")
		assert(near(library.animations.duration, file_library.animations.duration))
		player := r3d.LoadAnimationPlayer(model.skeleton, library)
		defer r3d.UnloadAnimationPlayer(player)
		r3d.PlayAnimation(&player, 0)
		// The bundled player uses seconds despite the generated binding comment.
		r3d.SetAnimationTime(&player, 0, 0.25)
		r3d.UpdateAnimationPlayer(&player, 0)
		for bone, i in model.skeleton.bones[:model.skeleton.boneCount] {
			assert(bone.name == file_model.skeleton.bones[i].name)
			assert(player.localPose[i] == file_player.localPose[i], "file and memory imports evaluate the same joint pose")
		}
	}
	// Failed parses must release their per-import property store too.
	invalid := [?]u8{0, 1, 2, 3}
	assert(bridge.load_importer_from_memory(&invalid[0], u32(len(invalid)), "fbx", {}) == nil)

	left, _ := ecs.find_entity_by_id(world, "left")
	left_texture := ctx.animation_players[left].player.skinTexture
	before := state(world, entity)
	force_revision(manager, Strut)
	bridge.update_animations(ctx, world, manager, 0)
	_, ready = bridge.animation_player(ctx, entity)
	assert(ready && near(state(world, entity).elapsed, before.elapsed), "FBX reload preserves playback")
	assert(ctx.models[Strut].animations.animations.channelCount == 52, "FBX reload also keeps pivot channels")
	assert(ctx.animation_players[left].player.skinTexture == left_texture, "FBX reload leaves other models' players intact")
}
