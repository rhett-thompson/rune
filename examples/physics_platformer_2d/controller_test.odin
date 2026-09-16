package main

import "core:testing"
import "rune:ecs"
import "rune:scene"

@(test)
authored_platformer_grounds_moves_and_jumps :: proc(t: ^testing.T) {
	r := ecs.init_registry(); defer ecs.destroy_registry(&r)
	assert(ecs.register_builtin_components(&r))
	layers := make(map[string]u8); defer delete(layers)
	layers["Gameplay"] = 1
	w, ok := scene.load_with_layers("examples/physics_platformer_2d/scenes/main.scene.json", &r, layers)
	defer scene.clear_load_error()
	if !testing.expect(t, ok, scene.last_load_error()) {return}
	defer ecs.destroy(&w)
	e, _ := ecs.find_entity_by_id(&w, "player")
	for _ in 0..<180 {ecs.physics_2d_update(&w, 1.0/60)}
	state, _ := ecs.get_character_controller_2d_state(&w, e)
	testing.expect(t, state.active && state.grounded, "authored capsule lands on the floor")
	pose, _ := ecs.get_transform(&w, e)
	testing.expect(t, pose.position.y > 445 && pose.position.y < 455, "capsule retains original bounds")
	ecs.character_controller_2d_move(&w, e, 1)
	ecs.physics_2d_update(&w, 1.0/60)
	body, _ := ecs.get_rigid_body_2d(&w, e)
	testing.expect(t, body.velocity.x > 210, "original movement speed")
	ecs.character_controller_2d_jump(&w, e)
	ecs.physics_2d_update(&w, 1.0/60)
	body, _ = ecs.get_rigid_body_2d(&w, e)
	state, _ = ecs.get_character_controller_2d_state(&w, e)
	testing.expect(t, body.velocity.y < -300 && !state.grounded, "jump works without a custom controller")
}
