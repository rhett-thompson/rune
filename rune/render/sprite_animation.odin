package render

import "rune:assets"
import "rune:ecs"
import "core:math"

// update_sprite_animators resolves animation assets after game update systems
// and before drawing, so code-driven clip changes appear in the same frame.
update_sprite_animators :: proc(
	world: ^ecs.World,
	asset_manager: ^assets.Asset_Manager,
	delta_time: f32,
) {
	if world == nil || asset_manager == nil {return}
	ecs.clear_sprite_animation_events(world)
	for entity in ecs.entities_with_component(world, "SpriteAnimator") {
		animator, has_animator := ecs.get_sprite_animator(world, entity)
		sprite, has_sprite := ecs.get_sprite_renderer(world, entity)
		state, has_state := ecs.get_sprite_animation_state(world, entity)
		if !has_animator || !has_sprite || !has_state {continue}
		animation, revision, loaded := assets.animation(asset_manager, animator.animation)
		if !loaded {continue}
		if state.finished && state.next_clip != "" {
			if _, valid := animation.clips[state.next_clip]; valid {
				ecs.play_sprite_animation(world,entity,state.next_clip)
				animator, _ = ecs.get_sprite_animator(world,entity)
				state, _ = ecs.get_sprite_animation_state(world,entity)
			} else {
				assets.report_failure(asset_manager,{kind=.Animation,operation=.Load,source_path=animator.animation,
					field="SpriteAnimator.next_clip",asset_path=state.next_clip,detail="queued clip is not defined"})
				state.next_clip = ""
			}
		}
		clip, has_clip := animation.clips[animator.clip]
		if !has_clip || len(clip.frames) == 0 {
			assets.report_failure(
				asset_manager,
				assets.Diagnostic {
					kind = .Animation,
					operation = .Load,
					source_path = animator.animation,
					field = "SpriteAnimator.clip",
					asset_path = animator.clip,
					detail = "clip is not defined by the animation asset",
				},
			)
			continue
		}
		assets.resolve_asset_failure(
			asset_manager,
			animator.animation,
			"SpriteAnimator.clip",
			animator.clip,
		)

		advance_sprite_animation(world, entity, animator, &state, clip, revision, delta_time)

		texture, texture_loaded := assets.texture(
			asset_manager,
			animation.texture,
			animator.animation,
			"$.texture",
		)
		if texture_loaded {
			columns := (texture.width - clip.origin[0]) / animation.frame_size[0]
			rows := (texture.height - clip.origin[1]) / animation.frame_size[1]
			frame_count := columns * rows
			frames_valid := columns > 0 && rows > 0
			if frames_valid {
				for configured_frame in clip.frames {
					if configured_frame < 0 || configured_frame >= frame_count {
						frames_valid = false
						break
					}
				}
			}
			if frames_valid {
				frame := clip.frames[state.frame]
				sprite.texture = animation.texture
				sprite.source = {
					f32(clip.origin[0] + frame % columns * animation.frame_size[0]),
					f32(clip.origin[1] + frame / columns * animation.frame_size[1]),
					f32(animation.frame_size[0]),
					f32(animation.frame_size[1]),
				}
				ecs.set_sprite_renderer(world, entity, sprite)
				assets.resolve_asset_failure(
					asset_manager,
					animator.animation,
					animator.clip,
					animator.animation,
				)
			} else {
				assets.report_failure(
					asset_manager,
					assets.Diagnostic {
						kind = .Animation,
						operation = .Load,
						source_path = animator.animation,
						field = animator.clip,
						asset_path = animator.animation,
						detail = "frame index is outside the sprite sheet",
					},
				)
			}
		}
		ecs.set_sprite_animation_state(world, entity, state)
	}
}

// Advance one resolved clip without graphics. The caller owns the state and
// clears the World event buffer once before updating all animators.
advance_sprite_animation :: proc(
	world: ^ecs.World,
	entity: ecs.Entity,
	animator: ecs.SpriteAnimator,
	state: ^ecs.Sprite_Animation_State,
	clip: assets.Animation_Clip,
	revision: u64,
	delta_time: f32,
) {
	if world == nil || state == nil || len(clip.frames) == 0 {return}
	if !state.initialized {
		state.initialized = true
		state.playing = animator.autoplay
	}
	if state.asset_revision != revision {
		state.asset_revision = revision
		state.elapsed = 0
		state.frame = 0
		state.finished = false
		state.markers_started = false
	}
	if !animation_can_advance(state, len(clip.frames), clip.fps, animator.speed, delta_time) {return}
	if !state.markers_started {
		state.markers_started = true
		for marker in clip.markers {
			if marker.frame == state.frame {
				if !emit_animation_marker(world, entity, animator, marker) {break}
			}
		}
	}
	previous_frame := state.frame
	steps := advance_animation_state(state, len(clip.frames), clip.fps, clip.loop, animator.speed, delta_time)
	if steps <= 0 || len(clip.markers) == 0 {return}
	// Markers are sorted by frame. Visit entries in timeline order, retaining
	// JSON order for ties. Once the buffer fills, playback still reaches its pose.
	for cycle: f64 = 0; ; cycle += 1 {
		for marker in clip.markers {
			distance := cycle * f64(len(clip.frames)) + f64(marker.frame - previous_frame)
			if distance <= 0 {continue}
			if distance > steps {return}
			if !emit_animation_marker(world, entity, animator, marker) {return}
		}
		if !clip.loop {return}
	}
}

@(private)
emit_animation_marker :: proc(world: ^ecs.World, entity: ecs.Entity, animator: ecs.SpriteAnimator, marker: assets.Animation_Marker) -> bool {
	return ecs.append_sprite_animation_event(world, {
		entity = entity, animation = animator.animation, clip = animator.clip,
		name = marker.name, frame = marker.frame,
	})
}

@(private)
animation_can_advance :: proc(state: ^ecs.Sprite_Animation_State, frame_count: int, fps, speed, delta_time: f32) -> bool {
	return state != nil && state.playing && frame_count > 0 &&
	       fps > 0 && speed > 0 && delta_time > 0 &&
	       !math.is_nan(fps) && !math.is_inf(fps) &&
	       !math.is_nan(speed) && !math.is_inf(speed) &&
	       !math.is_nan(delta_time) && !math.is_inf(delta_time)
}

// advance_animation_state is separated from asset and renderer state so tools
// can validate looping and one-shot playback without opening a window.
advance_animation_state :: proc(
	state: ^ecs.Sprite_Animation_State,
	frame_count: int,
	fps: f32,
	loop: bool,
	speed, delta_time: f32,
) -> f64 {
	if !animation_can_advance(state, frame_count, fps, speed, delta_time) {return 0}
	frame_duration := 1 / f64(fps)
	state.elapsed += f64(delta_time) * f64(speed)
	steps := math.floor(state.elapsed / frame_duration)
	if steps <= 0 {return 0}
	// Use the same quotient for the remainder. fmod(1, 0.1) can return almost
	// 0.1 even though floor(1 / 0.1) is 10, incorrectly advancing again next tick.
	state.elapsed = max(0, state.elapsed - steps * frame_duration)
	if loop {
		state.frame = (state.frame + int(math.mod(steps, f64(frame_count)))) % frame_count
		return steps
	}
	remaining := frame_count - 1 - state.frame
	if steps >= f64(remaining) {
		state.frame = frame_count - 1
		state.elapsed = 0
		state.playing = false
		state.finished = true
		return f64(remaining)
	}
	state.frame += int(steps)
	return steps
}
