package ui

import "core:testing"
import "rune:input"

@(test)
stick_navigation_merges_with_mapped_actions :: proc(t: ^testing.T) {
	controls := Inputs{pointer = {12, 34}, next = true, activate = true, blocked = true}
	merged := merge_nav_inputs(controls, {down = true, left = true})
	testing.expect(t, merged.next && merged.left && merged.activate && merged.blocked)
	testing.expect(t, merged.pointer == controls.pointer && !merged.previous && !merged.right)
	merged = merge_nav_inputs(merged, {up = true, right = true})
	testing.expect(t, merged.next && merged.previous && merged.left && merged.right,
		"opposing inputs remain explicit so widget navigation can cancel them")
}

@(test)
focus_reset_keeps_navigation_configuration :: proc(t: ^testing.T) {
	menu := Context{focus_id = 1, active_id = 2,
		nav = input.Nav_State{threshold = 0.75, delay = 0.5, repeat = 0.2, direction = .Down, remaining = 0.1}}
	reset_focus(&menu)
	testing.expect(t, menu.focus_id == 0 && menu.active_id == 0 && menu.nav.direction == .None && menu.nav.remaining == 0)
	testing.expect(t, menu.nav.threshold == 0.75 && menu.nav.delay == 0.5 && menu.nav.repeat == 0.2)
}
