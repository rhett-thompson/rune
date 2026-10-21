package r3d_bridge

import "core:testing"
import "rune:profile"

when profile.Player_Build {
	@(test)
	player_debug_overlays_skip_renderer_and_world_access :: proc(t: ^testing.T) {
		// Even explicitly enabled development settings require neither a World
		// nor a graphics context in player builds because no overlay is drawn.
		draw_debug_overlays(nil, {}, {grid_slices = 20, grid_spacing = 1, draw_colliders = true})
	}
}
