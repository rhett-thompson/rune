package main

import "core:testing"
import rune "rune:core"
import "rune:ecs"
import "rune:input"

@(test)
pause_and_restart_work_without_simulation :: proc(t: ^testing.T) {
	controls, ok := input.load("examples/tetris/input/default.input.json")
	assert(ok); defer input.destroy(&controls)
	engine := rune.Engine{input = controls}
	w := ecs.init(); defer ecs.destroy(&w)
	game = {}; defer {game = {}}
	assert(input.inject_action(&engine.input, "pause", true))
	tetris_controls(&engine, &w)
	testing.expect(t, rune.is_paused(&engine))
	tetris_controls(&engine, &w)
	testing.expect(t, rune.is_paused(&engine), "held pause does not toggle repeatedly")
	input.inject_action(&engine.input, "pause", false); tetris_controls(&engine, &w)
	input.inject_action(&engine.input, "pause", true); tetris_controls(&engine, &w)
	testing.expect(t, !rune.is_paused(&engine), "UI update can resume a paused simulation")
	rune.set_paused(&engine, true); game.score = 100; game.game_over = true
	input.inject_action(&engine.input, "restart", true); tetris_controls(&engine, &w)
	testing.expect(t, !rune.is_paused(&engine) && !game.game_over && game.score == 0 && game.level == 1)
}
