package r3d_bridge

import "core:fmt"
import "core:math"
import "core:strings"
import rl "vendor:raylib"
import r3d "r3d:r3d"
import "rune:assets"
import "rune:ecs"

Model_Player :: struct {
	blend_pose: []rl.Matrix,
	blend_elapsed, blend_duration: f32,
	player:     r3d.AnimationPlayer,
	path:       string,
	clip_index: i32,
	pose_time:  f32,
	ready:      bool,
}

destroy_animation_players :: proc(ctx: ^Context) {
	for entity, cached in ctx.animation_players {
		delete(cached.blend_pose)
		r3d.UnloadAnimationPlayer(cached.player)
		delete_key(&ctx.animation_players, entity)
	}
}

invalidate_model_players :: proc(ctx: ^Context, path: string) {
	for entity, cached in ctx.animation_players {
		if cached.path != path {continue}
		delete(cached.blend_pose)
		r3d.UnloadAnimationPlayer(cached.player)
		delete_key(&ctx.animation_players, entity)
	}
}

animation_library_valid :: proc(model: r3d.Model, library: r3d.AnimationLib) -> bool {
	if !r3d.IsSkeletonValid(model.skeleton) ||
	   library.count <= 0 ||
	   library.animations == nil {return false}
	for clip in (cast([^]r3d.Animation)library.animations)[:library.count] {
		if clip.boneCount != model.skeleton.boneCount ||
		   clip.duration <= 0 ||
		   clip.ticksPerSecond <= 0 ||
		   math.is_nan(clip.duration) ||
		   math.is_inf(clip.duration) ||
		   math.is_nan(clip.ticksPerSecond) ||
		   math.is_inf(clip.ticksPerSecond) {return false}
		for channel in clip.channels[:clip.channelCount] {
			if channel.boneIndex < 0 ||
			   channel.boneIndex >= model.skeleton.boneCount {return false}
		}
	}
	return true
}

report_animation_failure :: proc(
	manager: ^assets.Asset_Manager,
	path, detail: string,
	entity_id := "",
) {
	assets.report_failure(
		manager,
		{
			kind = .Animation,
			operation = .Load,
			source_path = entity_id,
			field = "ModelAnimator.clip",
			asset_path = path,
			detail = detail,
		},
	)
}

load_model_animations :: proc(
	ctx: ^Context,
	manager: ^assets.Asset_Manager,
	path: string,
) -> bool {
	asset, found := ctx.models[path]
	if !found {return false}
	if asset.animations_attempted {return asset.animations_loaded}
	asset.animations_attempted = true
	full_path := resolve_path(ctx, path)
	library := r3d.LoadAnimationLib(fmt.ctprintf("%s", full_path))
	if !animation_library_valid(asset.model, library) {
		r3d.UnloadAnimationLib(library)
		ctx.models[path] = asset
		report_animation_failure(
			manager,
			path,
			"model has no compatible embedded skeletal animations",
		)
		return false
	}
	asset.animations = library
	asset.animations_loaded = true
	ctx.models[path] = asset
	assets.resolve_asset_failure(manager, "", "ModelAnimator.clip", path)
	return true
}

// Call once from a simulation update callback. draw_scene prepares poses at
// zero delta, so paused rendering and captures never advance animation time.
update_animations :: proc(
	ctx: ^Context,
	world: ^ecs.World,
	manager: ^assets.Asset_Manager,
	dt: f32,
) {
	if dt < 0 || math.is_nan(dt) || math.is_inf(dt) {return}
	prepare_animations(ctx, world, manager, dt, true)
}

prepare_animations :: proc(
	ctx: ^Context,
	world: ^ecs.World,
	manager: ^assets.Asset_Manager,
	dt: f32,
	publish: bool,
) {
	if !ctx.initialized {return}
	if ctx.animation_world_generation != world.generation {
		destroy_animation_players(ctx)
		ctx.animation_world_generation = world.generation
	}
	for entity, cached in ctx.animation_players {
		renderer, rendered := ecs.get_model_renderer(world, entity)
		_, animated := ecs.get_model_animator(world, entity)
		if !ecs.is_alive(world, entity) ||
		   !rendered ||
		   !animated ||
		   renderer.model != cached.path {
			delete(cached.blend_pose)
			r3d.UnloadAnimationPlayer(cached.player)
			delete_key(&ctx.animation_players, entity)
		}
	}
	for entity, animator in world.model_animators {
		renderer, found := ecs.get_model_renderer(world, entity)
		if !found {continue}
		model, loaded := load_model(ctx, manager, renderer.model)
		if !loaded || !load_model_animations(ctx, manager, renderer.model) {continue}
		asset := ctx.models[renderer.model]
		cached, exists := ctx.animation_players[entity]
		if !exists {
			cached = Model_Player {
				player     = r3d.LoadAnimationPlayer(model.skeleton, asset.animations),
				path       = retain_path(ctx, renderer.model),
				clip_index = -1,
			}
			if !r3d.IsAnimationPlayerValid(cached.player) {
				r3d.UnloadAnimationPlayer(cached.player)
				report_animation_failure(
					manager,
					renderer.model,
					"could not create animation player",
				)
				continue
			}
		}
		entity_id, named := ecs.entity_id(world, entity)
		if !named || entity_id == "" {entity_id = fmt.tprintf("@%d", entity)}
		index: i32 = 0
		if animator.clip !=
		   "" {index = r3d.GetAnimationIndex(asset.animations, fmt.ctprintf("%s", animator.clip))}
		if index < 0 || index >= asset.animations.count {
			cached.ready = false
			ctx.animation_players[entity] = cached
			report_animation_failure(
				manager,
				renderer.model,
				fmt.tprintf("clip '%s' was not found", animator.clip),
				entity_id,
			)
			continue
		}
		assets.resolve_asset_failure(manager, entity_id, "ModelAnimator.clip", renderer.model)
		clip := (cast([^]r3d.Animation)asset.animations.animations)[index]
		if cached.ready && cached.clip_index != index {
			delete(cached.blend_pose)
			cached.blend_pose = nil
			cached.blend_duration, cached.blend_elapsed = animator.blend_time, 0
			if animator.blend_time > 0 {
				cached.blend_pose = make([]rl.Matrix,cached.player.skeleton.boneCount)
				copy(cached.blend_pose,cached.player.localPose[:cached.player.skeleton.boneCount])
			}
		}
		state := world.model_animation_states[entity]
		if !state.initialized {
			state.playing = animator.autoplay
			state.elapsed = clip.duration / clip.ticksPerSecond if animator.speed < 0 else 0
			state.initialized = true
		}
		state.duration = clip.duration / clip.ticksPerSecond
		if state.elapsed < 0 {state.elapsed = state.duration}
		state.elapsed = clamp(state.elapsed, 0, state.duration)
		r3d.PlayAnimation(&cached.player, index)
		r3d.SetAnimationSpeed(&cached.player, index, animator.speed)
		r3d.SetAnimationLoop(&cached.player, index, animator.loop)
		// The bundled native player uses seconds; imported clip durations use ticks.
		r3d.SetAnimationTime(&cached.player, index, state.elapsed)
		// SetAnimationTime wraps an exact end time to zero even for non-looping
		// clips. Preserve that endpoint for stopped poses and reverse playback.
		if state.elapsed ==
		   state.duration {cached.player.states[index].currentTime = state.elapsed}
		if !state.playing {r3d.PauseAnimation(&cached.player)}
		if publish && state.playing {r3d.AdvanceAnimationTime(&cached.player, dt)}
		state.elapsed = r3d.GetAnimationTime(cached.player, index)
		state.playing = r3d.IsAnimationPlaying(cached.player)
		state.finished =
			!animator.loop &&
			!state.playing &&
			(state.elapsed >= state.duration if animator.speed > 0 else state.elapsed <= 0)
		blending := len(cached.blend_pose)>0
		if blending && publish && (state.playing || state.finished) {cached.blend_elapsed += dt}
		if !cached.ready || cached.clip_index != index || cached.pose_time != state.elapsed || blending {
			r3d.ComputeAnimationLocalPose(&cached.player)
			if blending {
				weight := clamp(cached.blend_elapsed/cached.blend_duration,0,1)
				for pose, bone in cached.blend_pose {
					cached.player.localPose[bone] = blend_local_pose(pose,cached.player.localPose[bone],weight)
				}
				if weight == 1 {delete(cached.blend_pose); cached.blend_pose=nil}
			}
			r3d.ComputeAnimationModelPose(&cached.player)
			r3d.UploadAnimationPose(&cached.player)
		}
		cached.ready = true
		cached.clip_index = index
		cached.pose_time = state.elapsed
		ctx.animation_players[entity] = cached
		if publish {world.model_animation_states[entity] = state}
	}
}

// Borrowed native player; mutations to its state may be overwritten by the next
// Rune update. Lifetime ends on component removal, model reload, or shutdown.
animation_player :: proc(ctx: ^Context, entity: ecs.Entity) -> (r3d.AnimationPlayer, bool) {
	cached, found := ctx.animation_players[entity]
	return cached.player, found && cached.ready
}

// Clip names are copied into frame scratch rather than exposing imported memory.
animation_clips :: proc(ctx: ^Context, manager: ^assets.Asset_Manager, path: string) -> []string {
	_, loaded := load_model(ctx, manager, path)
	if !loaded || !load_model_animations(ctx, manager, path) {return nil}
	library := ctx.models[path].animations
	names := make([]string, library.count, context.temp_allocator)
	for &clip, i in (cast([^]r3d.Animation)library.animations)[:library.count] {
		name := strings.string_from_ptr(cast(^u8)&clip.name[0], len(clip.name))
		end := strings.index_byte(name, 0)
		if end >= 0 {name = name[:end]}
		names[i], _ = strings.clone(name, context.temp_allocator)
	}
	return names
}
