package ui

import "core:fmt"
import "core:testing"

scroll_focus_test_visible :: proc(ctx:^Context,widget,viewport:string) -> bool {
	box,found:=bounds(ctx,widget)
	clip,clip_found:=bounds(ctx,viewport)
	return found && clip_found && box.x>=clip.x-0.01 && box.y>=clip.y-0.01 &&
		box.x+box.width<=clip.x+clip.width+0.01 && box.y+box.height<=clip.y+clip.height+0.01
}

@(test)
scroll_navigation_reveals_rows_in_both_directions_without_idle_snapback :: proc(t:^testing.T) {
	ctx:Context;testing.expect(t,init(&ctx,measure=scroll_test_measure));defer destroy(&ctx)
	ctx.style.height=30
	scroll_test_layout(&ctx);scroll_test_layout(&ctx)
	for index in 1..<20 {
		scroll_test_layout(&ctx,{next=true})
		testing.expect(t,focused(&ctx,fmt.tprintf("row_%d",index)))
		scroll_test_layout(&ctx)
		testing.expect(t,scroll_focus_test_visible(&ctx,fmt.tprintf("row_%d",index),"list"),
			"Navigation reveals each newly focused binding, including consecutive rows beyond the viewport")
	}
	testing.expect(t,scroll_test_data(&ctx).position[1]<0)
	for index:=18;index>=0;index-=1 {
		scroll_test_layout(&ctx,{previous=true});scroll_test_layout(&ctx)
		testing.expect(t,focused(&ctx,fmt.tprintf("row_%d",index)) &&
			scroll_focus_test_visible(&ctx,fmt.tprintf("row_%d",index),"list"))
	}
	testing.expect(t,scroll_test_data(&ctx).position==[2]f32{})
	scroll_test_layout(&ctx,{pointer={40,40},scroll={0,-2}})
	before:=scroll_test_data(&ctx).position
	for _ in 0..<3 {scroll_test_layout(&ctx,{pointer={40,40}})}
	testing.expect(t,scroll_test_data(&ctx).position==before,"Idle focus preserves manual wheel scrolling")
	scroll_test_layout(&ctx,{pointer={40,40},blocked=true,next=true});scroll_test_layout(&ctx,{pointer={40,40}})
	testing.expect(t,scroll_test_data(&ctx).position==before,"Blocked navigation cannot reveal or change focus")
	scroll_test_layout(&ctx,{pointer={40,40},next=true});scroll_test_layout(&ctx,{pointer={40,40}})
	testing.expect(t,scroll_focus_test_visible(&ctx,"row_1","list"),"Explicit navigation resumes focus following after manual scrolling")
}

scroll_focus_test_footer_layout :: proc(ctx:^Context,controls:Inputs={}) {
	assert(begin(ctx,{320,300},controls,1.0/60))
	panel(ctx,"root",{layout={sizing={width=grow({}),height=grow({})},layoutDirection=.TopToBottom,childGap=8}})
	scroll_panel(ctx,"list",{layout={sizing={width=fixed(220),height=fixed(100)},layoutDirection=.TopToBottom}},false,true)
	scroll_test_rows(ctx,20)
	end_panel(ctx)
	button(ctx,"footer_apply","Apply")
	end_panel(ctx);assert(finish(ctx))
}

@(test)
scroll_navigation_wraps_through_footer_and_returns_to_hidden_rows :: proc(t:^testing.T) {
	ctx:Context;testing.expect(t,init(&ctx,measure=scroll_test_measure));defer destroy(&ctx)
	ctx.style.height=30
	scroll_focus_test_footer_layout(&ctx);scroll_focus_test_footer_layout(&ctx)
	scroll_focus_test_footer_layout(&ctx,{previous=true});scroll_focus_test_footer_layout(&ctx)
	testing.expect(t,focused(&ctx,"footer_apply") && scroll_test_data(&ctx).position==[2]f32{},
		"A footer outside the list does not scroll it")
	scroll_focus_test_footer_layout(&ctx,{previous=true});scroll_focus_test_footer_layout(&ctx)
	testing.expect(t,focused(&ctx,"row_19") && scroll_focus_test_visible(&ctx,"row_19","list"),
		"Returning from the footer reveals the last binding even when it was initially hidden")
	before:=scroll_test_data(&ctx).position
	scroll_focus_test_footer_layout(&ctx,{next=true});scroll_focus_test_footer_layout(&ctx)
	testing.expect(t,focused(&ctx,"footer_apply") && scroll_test_data(&ctx).position==before)
	scroll_focus_test_footer_layout(&ctx,{next=true});scroll_focus_test_footer_layout(&ctx)
	testing.expect(t,focused(&ctx,"row_0") && scroll_focus_test_visible(&ctx,"row_0","list"),
		"Wrapping back from the footer reveals the first binding")
}

scroll_focus_test_nested_layout :: proc(ctx:^Context,controls:Inputs={}) {
	assert(begin(ctx,{600,400},controls,1.0/60))
	panel(ctx,"root",{layout={sizing={width=grow({}),height=grow({})}}})
	scroll_panel(ctx,"outer",{layout={sizing={width=fixed(240),height=fixed(140)},layoutDirection=.TopToBottom}},false,true)
	panel(ctx,"spacer",{layout={sizing={width=grow({}),height=fixed(80)}}});end_panel(ctx)
	scroll_panel(ctx,"inner",{layout={sizing={width=fixed(180),height=fixed(130)},layoutDirection=.TopToBottom}},false,true)
	scroll_test_rows(ctx,20)
	end_panel(ctx);end_panel(ctx)
	scroll_panel(ctx,"other",{layout={sizing={width=fixed(180),height=fixed(140)},layoutDirection=.TopToBottom}},false,true)
	for index in 0..<10 {button(ctx,fmt.tprintf("other_%d",index),"Other list")}
	end_panel(ctx);end_panel(ctx);assert(finish(ctx))
}

@(test)
scroll_navigation_reveals_every_nested_clip_without_moving_sibling_lists :: proc(t:^testing.T) {
	ctx:Context;testing.expect(t,init(&ctx,measure=scroll_test_measure));defer destroy(&ctx)
	ctx.style.height=30
	scroll_focus_test_nested_layout(&ctx);scroll_focus_test_nested_layout(&ctx)
	for _ in 1..<20 {scroll_focus_test_nested_layout(&ctx,{next=true})}
	scroll_focus_test_nested_layout(&ctx)
	testing.expect(t,focused(&ctx,"row_19") && scroll_focus_test_visible(&ctx,"row_19","inner") &&
		scroll_focus_test_visible(&ctx,"row_19","outer"),"The focused row is visible through both nested clips")
	outer_before:=scroll_test_data(&ctx,"outer").position
	inner_before:=scroll_test_data(&ctx,"inner").position
	testing.expect(t,outer_before[1]<0 && inner_before[1]<0 && scroll_test_data(&ctx,"other").position==[2]f32{},
		"Only the focused widget's scroll ancestors move")
	for _ in 0..<10 {scroll_focus_test_nested_layout(&ctx,{next=true})}
	scroll_focus_test_nested_layout(&ctx)
	testing.expect(t,focused(&ctx,"other_9") && scroll_focus_test_visible(&ctx,"other_9","other"))
	testing.expect(t,scroll_test_data(&ctx,"outer").position==outer_before && scroll_test_data(&ctx,"inner").position==inner_before,
		"Navigating a sibling list preserves the previous list's position")
}

scroll_focus_test_dropdown_layout :: proc(ctx:^Context,state:^Dropdown,selection:^int,controls:Inputs={}) {
	assert(begin(ctx,{400,400},controls,1.0/60))
	panel(ctx,"root",{layout={sizing={width=grow({}),height=grow({})},layoutDirection=.TopToBottom,padding=padding(20)}})
	scroll_panel(ctx,"outer",{layout={sizing={width=fixed(240),height=fixed(80)},layoutDirection=.TopToBottom,childGap=8}},false,true)
	dropdown(ctx,"choice",state,selection,Dropdown_Test_Options,true,120)
	panel(ctx,"spacer",{layout={sizing={width=grow({}),height=fixed(200)}}});end_panel(ctx)
	button(ctx,"action","Hidden menu action")
	end_panel(ctx);end_panel(ctx);assert(finish(ctx))
}

@(test)
scroll_navigation_in_floating_dropdown_does_not_scroll_underlying_menu :: proc(t:^testing.T) {
	ctx:Context;testing.expect(t,init(&ctx,measure=scroll_test_measure));defer destroy(&ctx)
	ctx.style.height=30
	state:Dropdown;selection:=0
	scroll_focus_test_dropdown_layout(&ctx,&state,&selection)
	scroll_focus_test_dropdown_layout(&ctx,&state,&selection,{activate=true})
	scroll_focus_test_dropdown_layout(&ctx,&state,&selection)
	scroll_focus_test_dropdown_layout(&ctx,&state,&selection,{previous=true})
	scroll_focus_test_dropdown_layout(&ctx,&state,&selection)
	testing.expect(t,state.open && state.highlighted==7 && scroll_focus_test_visible(&ctx,"choice_option_7","choice_options"))
	testing.expect(t,scroll_test_data(&ctx,"outer").position==[2]f32{},"Floating option focus does not inherit the menu's clip")
	scroll_focus_test_dropdown_layout(&ctx,&state,&selection,{next=true})
	scroll_focus_test_dropdown_layout(&ctx,&state,&selection)
	testing.expect(t,state.highlighted==0 && scroll_test_data(&ctx,"outer").position==[2]f32{},
		"Wrapping popup navigation cannot reveal the sibling action tentatively focused by begin")
}
