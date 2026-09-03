package main

import "core:fmt"
import "rune:assets"
import "rune:ecs"
import "rune:render"
import "rune:scene"

main :: proc() {
	data, loaded := assets.load_animation_data(
		"examples/sprite_animation_2d/animations/coin.animation.json",
	)
	assert(loaded)
	defer assets.destroy_animation_data(&data)
	assert(data.texture == "../assets/brackeys_platformer_assets/sprites/coin.png")
	assert(data.frame_size == {16, 16})
	spin, has_spin := data.clips["spin"]
	assert(has_spin && len(spin.frames) == 12 && spin.frames[0] == 0 && spin.frames[11] == 11)
	assert(spin.fps == 12 && spin.loop)
	knight_data, knight_loaded := assets.load_animation_data(
		"examples/sprite_animation_2d/animations/knight.animation.json",
	)
	assert(knight_loaded)
	defer assets.destroy_animation_data(&knight_data)
	assert(knight_data.frame_size == {32, 32})
	idle, has_idle := knight_data.clips["idle"]
	run, has_run := knight_data.clips["run"]
	roll, has_roll := knight_data.clips["roll"]
	hit, has_hit := knight_data.clips["hit"]
	death, has_death := knight_data.clips["death"]
	assert(has_idle && idle.origin == {0, 0} && len(idle.frames) == 4)
	assert(has_run && run.origin == {0, 64} && len(run.frames) == 16)
	assert(has_roll && roll.origin == {0, 160} && len(roll.frames) == 8 && !roll.loop)
	assert(has_hit && hit.origin == {0, 192} && len(hit.frames) == 4 && !hit.loop)
	assert(has_death && death.origin == {0, 224} && len(death.frames) == 4 && !death.loop)

	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	world, scene_loaded := scene.load(
		"examples/sprite_animation_2d/scenes/main.scene.json",
		&registry,
	)
	assert(scene_loaded)
	defer ecs.destroy(&world)
	coin, found := ecs.find_entity_by_id(&world, "coin")
	assert(found)
	sprite, has_sprite := ecs.get_sprite_renderer(&world, coin)
	assert(has_sprite && sprite.tint == {255, 238, 128, 255})
	animator, has_animator := ecs.get_sprite_animator(&world, coin)
	assert(has_animator && animator.animation == "animations/coin.animation.json")
	assert(animator.clip == "spin" && animator.autoplay && animator.speed == 1)
	knight, knight_found := ecs.find_entity_by_id(&world, "knight")
	assert(knight_found)
	knight_animator, has_knight_animator := ecs.get_sprite_animator(&world, knight)
	assert(has_knight_animator && knight_animator.clip == "idle")
	assert(ecs.play_sprite_animation(&world, knight, "roll"))

	assert(ecs.play_sprite_animation(&world, coin, "reverse"))
	animator, _ = ecs.get_sprite_animator(&world, coin)
	state, has_state := ecs.get_sprite_animation_state(&world, coin)
	assert(has_state && animator.clip == "reverse" && state.playing)
	assert(ecs.pause_sprite_animation(&world, coin))
	state, _ = ecs.get_sprite_animation_state(&world, coin)
	assert(!state.playing)
	assert(ecs.resume_sprite_animation(&world, coin))
	state, _ = ecs.get_sprite_animation_state(&world, coin)
	render.advance_animation_state(&state, 4, 10, true, 1, 0.25)
	assert(state.frame == 2 && state.playing)
	render.advance_animation_state(&state, 4, 10, true, 1, 0.2)
	assert(state.frame == 0 && state.playing)
	state.frame = 2
	state.elapsed = 0
	state.playing = true
	render.advance_animation_state(&state, 4, 10, false, 1, 0.2)
	assert(state.frame == 3 && !state.playing)
	assert(ecs.stop_sprite_animation(&world, coin))

	fmt.println("sprite animation validation passed")
}
