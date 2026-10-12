package ui

import "core:math"
import "core:testing"
import clay "../../third_party/clay/clay-odin"
import rl "vendor:raylib"

Dropdown_Test_Options :: []string{"First","Second","Third","Fourth","Fifth","Sixth","Seventh","Eighth"}

dropdown_test_measure :: proc(text:string,size,spacing:f32) -> [2]f32 {return {f32(len(text))*size*0.5,size}}

dropdown_test_layout :: proc(ctx:^Context,state:^Dropdown,selection:^int,controls:Inputs={},options:[]string=Dropdown_Test_Options,enabled:bool=true,
	size:[2]f32={400,400},top:f32=20,nested:bool=false) -> (changed,action:bool) {
	assert(begin(ctx,size,controls,1.0/60))
	panel(ctx,"root",{layout={sizing={width=grow({}),height=grow({})},layoutDirection=.TopToBottom,padding=padding(20),childGap=8}})
	panel(ctx,"spacer",{layout={sizing={width=grow({}),height=fixed(top)}}});end_panel(ctx)
	if nested {scroll_panel(ctx,"outer",{layout={sizing={width=grow({}),height=fixed(80)},layoutDirection=.TopToBottom,childGap=8}},false,true)}
	changed=dropdown(ctx,"choice",state,selection,options,enabled,120)
	action=button(ctx,"action","Action")
	if nested {end_panel(ctx)}
	panel(ctx,"footer_spacer",{layout={sizing={width=grow({}),height=fixed(100)}}});end_panel(ctx)
	action=button(ctx,"footer_action","Footer action") || action
	end_panel(ctx)
	assert(finish(ctx))
	return
}

dropdown_test_click :: proc(ctx:^Context,state:^Dropdown,selection:^int,id:string) -> (changed,action:bool) {
	box,found:=bounds(ctx,id);assert(found)
	point:=[2]f32{box.x+box.width*0.5,box.y+box.height*0.5}
	dropdown_test_layout(ctx,state,selection,{pointer=point,pointer_down=true})
	return dropdown_test_layout(ctx,state,selection,{pointer=point})
}

@(test)
dropdown_pointer_selection_floats_without_moving_actions :: proc(t:^testing.T) {
	ctx:Context;testing.expect(t,init(&ctx,measure=dropdown_test_measure));defer destroy(&ctx)
	ctx.style.height=30
	state:Dropdown;selection:=0
	dropdown_test_layout(&ctx,&state,&selection)
	action_before,_:=bounds(&ctx,"action")
	changed,action:=dropdown_test_click(&ctx,&state,&selection,"choice")
	testing.expect(t,state.open && !changed && !action)
	action_after,_:=bounds(&ctx,"action")
	trigger,trigger_found:=bounds(&ctx,"choice");popup,popup_found:=bounds(&ctx,"choice_popup")
	testing.expect(t,trigger_found && popup_found && action_after==action_before,"A floating list leaves surrounding menu actions in place")
	testing.expect(t,math.abs(popup.width-trigger.width)<0.01 && math.abs(popup.y-trigger.y-trigger.height-4)<0.01,"The popup matches and anchors below its trigger")
	changed,action=dropdown_test_click(&ctx,&state,&selection,"choice_option_1")
	testing.expect(t,changed && selection==1 && !state.open && !action,"Selecting an overlapping option closes the popup and never activates the covered action")
	testing.expect(t,focused(&ctx,"choice"),"Selection returns focus to the trigger")
	dropdown_test_layout(&ctx,&state,&selection)
	dropdown_test_click(&ctx,&state,&selection,"choice")
	changed,action=dropdown_test_click(&ctx,&state,&selection,"choice_option_1")
	testing.expect(t,!changed && !state.open && !action,"Selecting the current value closes without reporting a change")
}

@(test)
dropdown_nested_scroll_popup_draws_and_selects_beyond_parent_clip :: proc(t:^testing.T) {
	ctx:Context;testing.expect(t,init(&ctx,measure=dropdown_test_measure));defer destroy(&ctx)
	ctx.style.height=30
	state:Dropdown;selection:=0
	dropdown_test_layout(&ctx,&state,&selection,nested=true)
	dropdown_test_layout(&ctx,&state,&selection,{activate=true},nested=true)
	dropdown_test_layout(&ctx,&state,&selection,nested=true)
	outer,outer_found:=bounds(&ctx,"outer");row,row_found:=bounds(&ctx,"choice_option_2")
	testing.expect(t,outer_found && row_found && row.y>outer.y+outer.height,"The test option lies outside the enclosing menu scroll viewport")
	clips:[16]rl.Rectangle;depth:=0;rendered:=false
	for command in ctx.commands.internalArray[:ctx.commands.length] {
		b:=command.boundingBox;box:=rl.Rectangle{b.x,b.y,b.width,b.height}
		if command.commandType==.ScissorStart {
			if depth>0 {box=intersect(box,clips[depth-1])}
			clips[depth]=box;depth+=1
		} else if command.commandType==.ScissorEnd {depth-=1}
		else if command.commandType==.Rectangle && command.id==clay.ID("choice_option_2").id {
			rendered=true
			testing.expect(t,depth>0 && clips[depth-1].y+clips[depth-1].height>=row.y+row.height,"Floating popup rendering uses its own viewport instead of inheriting the menu clip")
		}
	}
	testing.expect(t,rendered && depth==0)
	point:=[2]f32{row.x+row.width*0.5,row.y+row.height*0.5}
	dropdown_test_layout(&ctx,&state,&selection,{pointer=point,pointer_down=true},nested=true)
	changed,action:=dropdown_test_layout(&ctx,&state,&selection,{pointer=point},nested=true)
	testing.expect(t,changed && selection==2 && !state.open && !action,"A visible popup option remains clickable outside its original parent clip")
}

@(test)
dropdown_keyboard_wrap_reveals_options_and_cancel_keeps_selection :: proc(t:^testing.T) {
	ctx:Context;testing.expect(t,init(&ctx,measure=dropdown_test_measure));defer destroy(&ctx)
	ctx.style.height=30
	state:Dropdown;selection:=0
	dropdown_test_layout(&ctx,&state,&selection)
	changed,action:=dropdown_test_layout(&ctx,&state,&selection,{activate=true})
	testing.expect(t,state.open && !changed && !action,"Accept opens without immediately choosing a row")
	dropdown_test_layout(&ctx,&state,&selection,{previous=true})
	testing.expect(t,state.highlighted==7 && selection==0,"Up wraps within the popup without changing the committed value")
	dropdown_test_layout(&ctx,&state,&selection)
	viewport,found:=bounds(&ctx,"choice_options");row,row_found:=bounds(&ctx,"choice_option_7")
	testing.expect(t,found && row_found && row.y>=viewport.y && row.y+row.height<=viewport.y+viewport.height+0.01,"Keyboard navigation reveals an initially hidden option")
	changed,action=dropdown_test_layout(&ctx,&state,&selection,{activate=true})
	testing.expect(t,changed && selection==7 && !state.open && !action,"Accept commits only the highlighted row")
	dropdown_test_layout(&ctx,&state,&selection,{activate=true})
	dropdown_test_layout(&ctx,&state,&selection,{next=true})
	testing.expect(t,state.open && state.highlighted==0)
	changed,action=dropdown_test_layout(&ctx,&state,&selection,{cancel=true,activate=true})
	testing.expect(t,!state.open && selection==7 && !changed && !action,"Cancel wins over simultaneous accept and preserves the selected option")
}

@(test)
dropdown_outside_press_is_consumed_and_blocking_retains_state :: proc(t:^testing.T) {
	ctx:Context;testing.expect(t,init(&ctx,measure=dropdown_test_measure));defer destroy(&ctx)
	ctx.style.height=30
	state:Dropdown;selection:=0
	dropdown_test_layout(&ctx,&state,&selection)
	dropdown_test_layout(&ctx,&state,&selection,{activate=true})
	dropdown_test_layout(&ctx,&state,&selection,{blocked=true,cancel=true,next=true,activate=true})
	testing.expect(t,state.open && state.highlighted==0 && selection==0,"Console blocking leaves the choice untouched")
	footer,found:=bounds(&ctx,"footer_action");testing.expect(t,found)
	point:=[2]f32{footer.x+footer.width*0.5,footer.y+footer.height*0.5}
	changed,action:=dropdown_test_layout(&ctx,&state,&selection,{pointer=point,pointer_down=true})
	testing.expect(t,!state.open && !changed && !action,"An outside press closes without changing selection")
	_,action=dropdown_test_layout(&ctx,&state,&selection,{pointer=point})
	testing.expect(t,!action,"The outside release cannot leak to a menu action")
	_,action=dropdown_test_click(&ctx,&state,&selection,"footer_action")
	testing.expect(t,action,"The menu accepts a fresh click after dismissal")
}

@(test)
dropdown_empty_disabled_invalid_indices_and_small_windows_are_safe :: proc(t:^testing.T) {
	ctx:Context;testing.expect(t,init(&ctx,measure=dropdown_test_measure));defer destroy(&ctx)
	ctx.style.height=30
	state:=Dropdown{open=true};selection:=-1
	dropdown_test_layout(&ctx,&state,&selection,{activate=true},options={})
	testing.expect(t,!state.open && selection==-1)
	state.open=true
	dropdown_test_layout(&ctx,&state,&selection,{activate=true},enabled=false)
	testing.expect(t,!state.open && selection==-1)
	dropdown_test_layout(&ctx,&state,&selection)
	reset_focus(&ctx)
	dropdown_test_layout(&ctx,&state,&selection)
	dropdown_test_layout(&ctx,&state,&selection,{activate=true})
	testing.expect(t,state.open && state.highlighted==0 && selection==-1,"Invalid selection is not rewritten until the user chooses")
	dropdown_test_layout(&ctx,&state,&selection,{activate=true})
	testing.expect(t,!state.open && selection==0)
	dropdown_test_layout(&ctx,&state,&selection,size={400,160},top=70)
	dropdown_test_layout(&ctx,&state,&selection,{activate=true},size={400,160},top=70)
	popup,found:=bounds(&ctx,"choice_popup")
	testing.expect(t,found && popup.y>=0 && popup.y+popup.height<=160,"A popup near the bottom opens above and remains inside the window")
}
