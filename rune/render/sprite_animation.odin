package render

import "rune:assets"
import "rune:ecs"

// update_sprite_animators resolves animation assets after game update systems
// and before drawing, so code-driven clip changes appear in the same frame.
update_sprite_animators :: proc(
	world: ^ecs.World,
	asset_manager: ^assets.Asset_Manager,
	delta_time: f32,
) {
	if world == nil || asset_manager == nil {return}
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

		was_initialized := state.initialized
		if !was_initialized {
			state.initialized = true
			state.playing = animator.autoplay
		}
		if state.asset_revision != revision {
			state.asset_revision = revision
			state.elapsed = 0
			state.frame = 0
			state.finished = false
		}
		advance_animation_state(
			&state,
			len(clip.frames),
			clip.fps,
			clip.loop,
			animator.speed,
			delta_time,
		)

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

// advance_animation_state is separated from asset and renderer state so tools
// can validate looping and one-shot playback without opening a window.
advance_animation_state :: proc(
	state: ^ecs.Sprite_Animation_State,
	frame_count: int,
	fps: f32,
	loop: bool,
	speed, delta_time: f32,
) {
	if state == nil ||
	   !state.playing ||
	   frame_count <= 0 ||
	   fps <= 0 ||
	   speed <= 0 ||
	   delta_time <= 0 {return}
	frame_duration := 1 / (fps * speed)
	state.elapsed += delta_time
	steps := int(state.elapsed / frame_duration)
	if steps <= 0 {return}
	state.elapsed -= f32(steps) * frame_duration
	if loop {
		state.frame = (state.frame + steps) % frame_count
		return
	}
	remaining := frame_count - 1 - state.frame
	if steps >= remaining {
		state.frame = frame_count - 1
		state.elapsed = 0
		state.playing = false
		state.finished = true
		return
	}
	state.frame += steps
}
