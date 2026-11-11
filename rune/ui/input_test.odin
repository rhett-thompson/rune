package ui

import "core:testing"
import "rune:input"
import clay "../../third_party/clay/clay-odin"

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

button_icon_test_layout :: proc(ctx: ^Context, controls: Inputs = {}, text: string = "") -> bool {
	assert(begin(ctx, {240, 240}, controls, 1.0 / 60))
	panel(ctx, "root", {layout = {sizing = {width = grow({}), height = grow({})}, layoutDirection = .TopToBottom}})
	button(ctx, "plain", "Plain")
	pressed := button(ctx, "icon", text, icon = {id = 1, width = 32, height = 16}, icon_size = {48, 24}, icon_above = true)
	end_panel(ctx)
	assert(finish(ctx))
	return pressed
}

@(test)
button_icon_shares_pointer_and_navigation_with_its_button :: proc(t: ^testing.T) {
	ctx: Context
	if !testing.expect(t, init(&ctx, measure = scroll_test_measure)) {return}
	defer destroy(&ctx)
	ctx.style.height = 80
	testing.expect(t, !button_icon_test_layout(&ctx) && focused(&ctx, "plain"))
	testing.expect(t, len(ctx.previous_widgets) == 2, "The icon adds no focus stop")
	box, found := bounds(&ctx, "icon")
	if !testing.expect(t, found) {return}
	icon: clay.BoundingBox
	for command in ctx.commands.internalArray[:ctx.commands.length] {
		if command.commandType == .Image {icon = command.boundingBox; break}
	}
	if !testing.expect(t, icon.width == 48 && icon.height == 24, "The button emits an image at the supplied size") {return}
	testing.expect(t, icon.x >= box.x && icon.y >= box.y && icon.x + icon.width <= box.x + box.width && icon.y + icon.height <= box.y + box.height)
	center := [2]f32{icon.x + icon.width / 2, icon.y + icon.height / 2}
	testing.expect(t, !button_icon_test_layout(&ctx, {pointer = center, pointer_down = true}))
	testing.expect(t, button_icon_test_layout(&ctx, {pointer = center}) && focused(&ctx, "icon"), "Releasing on the icon activates its button")
	testing.expect(t, !button_icon_test_layout(&ctx, {pointer = center, pointer_down = true}))
	testing.expect(t, !button_icon_test_layout(&ctx, {pointer = {12, 12}}), "Releasing outside cancels the activation")
	reset_focus(&ctx)
	button_icon_test_layout(&ctx)
	testing.expect(t, button_icon_test_layout(&ctx, {next = true, activate = true}), "Focused accept activates the image-only button")

	button_icon_test_layout(&ctx, text = "Controller")
	caption: clay.BoundingBox
	for command in ctx.commands.internalArray[:ctx.commands.length] {
		if command.commandType == .Image {icon = command.boundingBox}
		if command.commandType == .Text && command.boundingBox.y >= box.y {caption = command.boundingBox}
	}
	testing.expect(t, caption.height > 0 && icon.y + icon.height <= caption.y && caption.y + caption.height <= box.y + box.height,
		"Icon and text stack within the same button")
}
