package ui

import "core:fmt"
import "core:testing"
import clay "../../third_party/clay/clay-odin"
import rl "vendor:raylib"

Scroll_Test_Data :: struct {
	position: [2]f32,
	viewport, content: clay.Dimensions,
	found: bool,
}

scroll_test_measure :: proc(text:string,size,spacing:f32) -> [2]f32 {return {f32(len(text))*size*0.5,size}}

scroll_test_data :: proc(ctx:^Context,id:string="list") -> Scroll_Test_Data {
	previous:=clay.GetCurrentContext(); defer clay.SetCurrentContext(previous)
	clay.SetCurrentContext(ctx.native)
	data:=clay.GetScrollContainerData(clay.ID(id))
	result:=Scroll_Test_Data{viewport=data.scrollContainerDimensions,content=data.contentDimensions,found=data.found}
	if data.found && data.scrollPosition!=nil {result.position=data.scrollPosition^}
	return result
}

scroll_test_bar_bounds :: proc(ctx:^Context,axis:int,thumb:bool=false,id:string="list") -> (rl.Rectangle,bool) {
	previous:=clay.GetCurrentContext(); defer clay.SetCurrentContext(previous)
	clay.SetCurrentContext(ctx.native)
	key:=scroll_thumb_id(clay.ID(id).id,axis) if thumb else scroll_track_id(clay.ID(id).id,axis)
	data:=clay.GetElementData(key); b:=data.boundingBox
	return {b.x,b.y,b.width,b.height},data.found
}

scroll_test_center :: proc(rect:rl.Rectangle) -> [2]f32 {return {rect.x+rect.width*0.5,rect.y+rect.height*0.5}}

scroll_test_thumb_drawn :: proc(ctx:^Context,axis:int,id:string="list") -> bool {
	key:=scroll_thumb_id(clay.ID(id).id,axis).id
	for command in ctx.commands.internalArray[:ctx.commands.length] {
		if command.commandType==.Rectangle && command.id==key && command.renderData.rectangle.backgroundColor[3]>0 {return true}
	}
	return false
}

scroll_test_rows :: proc(ctx:^Context,count:int,horizontal:bool=false) -> bool {
	clicked:=false
	for i in 0..<count {
		width:=fixed(600) if horizontal else grow({})
		panel(ctx,fmt.tprintf("row_box_%d",i),{layout={sizing={width=width,height=fixed(30)}}})
		clicked=button(ctx,fmt.tprintf("row_%d",i),fmt.tprintf("Row %d",i)) || clicked
		end_panel(ctx)
	}
	return clicked
}

scroll_test_layout :: proc(ctx:^Context,controls:Inputs={},horizontal:bool=false,size:[2]f32={220,120},count:int=20,fit_height:bool=false) -> bool {
	assert(begin(ctx,{500,400},controls,1.0/60))
	panel(ctx,"root",{layout={sizing={width=grow({}),height=grow({})},layoutDirection=.TopToBottom}})
	declaration:=Element{layout={sizing={width=fixed(size[0]),height=fixed(size[1])},layoutDirection=.TopToBottom}}
	if fit_height {declaration.layout.sizing.height=fit({max=size[1]})}
	scroll_panel(ctx,"list",declaration,horizontal,true)
	clicked:=scroll_test_rows(ctx,count,horizontal)
	end_panel(ctx); end_panel(ctx)
	assert(finish(ctx))
	return clicked
}

scroll_test_visible_button :: proc(ctx:^Context,count:int=20) -> ([2]f32,bool) {
	viewport,found:=bounds(ctx,"list"); if !found {return {},false}
	for i in 0..<count {
		box,present:=bounds(ctx,fmt.tprintf("row_%d",i)); if !present {continue}
		center:=scroll_test_center(box)
		if center[0]>viewport.x && center[0]<viewport.x+viewport.width &&
			center[1]>viewport.y && center[1]<viewport.y+viewport.height {return center,true}
	}
	return {},false
}

@(test)
scroll_wheel_moves_a_usable_step_and_idle_focus_does_not_snap_back :: proc(t:^testing.T) {
	ctx:Context; testing.expect(t,init(&ctx,measure=scroll_test_measure)); defer destroy(&ctx)
	ctx.style.height=30
	point:=[2]f32{40,40}
	scroll_test_layout(&ctx,{pointer=point}); scroll_test_layout(&ctx,{pointer=point})
	focused_before:=ctx.focus_id
	scroll_test_layout(&ctx,{pointer=point,scroll={0,-1}})
	data:=scroll_test_data(&ctx)
	testing.expect(t,data.found && data.position==[2]f32{0,-60},"One wheel notch moves 60 pixels through the actual Clay layout")
	for _ in 0..<4 {scroll_test_layout(&ctx,{pointer=point})}
	testing.expect(t,scroll_test_data(&ctx).position==data.position && ctx.focus_id==focused_before,
		"An idle keyboard focus must not pull wheel-scrolled content back to the old focused row")
	scroll_test_layout(&ctx,{pointer=point,scroll={0,-1000}})
	bottom:=scroll_test_data(&ctx)
	testing.expect(t,bottom.position[1]==-max(bottom.content.height-bottom.viewport.height,0),"Scrolling clamps at the last content edge")
	scroll_test_layout(&ctx,{pointer=point,scroll={0,1000}})
	testing.expect(t,scroll_test_data(&ctx).position==[2]f32{},"Scrolling clamps at the first content edge")
	ctx.style.scroll_step=90
	scroll_test_layout(&ctx,{pointer=point,scroll={0,-1}})
	testing.expect(t,scroll_test_data(&ctx).position[1]==-90,"Per-menu wheel speed applies without changing Clay or frame time")
}

@(test)
scroll_gutter_wheel_and_drag_own_pointer_until_release :: proc(t:^testing.T) {
	ctx:Context; testing.expect(t,init(&ctx,measure=scroll_test_measure)); defer destroy(&ctx)
	ctx.style.height=30
	scroll_test_layout(&ctx); scroll_test_layout(&ctx)
	track,track_found:=scroll_test_bar_bounds(&ctx,1)
	testing.expect(t,track_found && track.width>0 && track.height>0)
	scroll_test_layout(&ctx,{pointer=scroll_test_center(track),scroll={0,-1}})
	testing.expect(t,scroll_test_data(&ctx).position[1]==-60,"The wheel works over the scrollbar gutter as well as the content")
	thumb,thumb_found:=scroll_test_bar_bounds(&ctx,1,true)
	testing.expect(t,thumb_found)
	testing.expect(t,!scroll_test_layout(&ctx,{pointer=scroll_test_center(thumb),pointer_down=true}))
	testing.expect(t,ctx.scroll_drag_id==clay.ID("list").id && ctx.active_id==0,"A thumb press belongs to the scroll viewport, not a binding button")
	testing.expect(t,!scroll_test_layout(&ctx,{pointer={track.x+track.width*0.5,track.y+track.height+50},pointer_down=true}))
	bottom:=scroll_test_data(&ctx)
	testing.expect(t,bottom.position[1]==-max(bottom.content.height-bottom.viewport.height,0),"Dragging past the track reaches the last row and clamps")
	button_point,button_found:=scroll_test_visible_button(&ctx)
	testing.expect(t,button_found)
	testing.expect(t,!scroll_test_layout(&ctx,{pointer=button_point}),"Releasing a thumb drag over a binding button cannot activate that button")
	testing.expect(t,ctx.scroll_drag_id==0 && ctx.active_id==0)
	button_point,button_found=scroll_test_visible_button(&ctx)
	testing.expect(t,button_found)
	testing.expect(t,!scroll_test_layout(&ctx,{pointer=button_point,pointer_down=true}))
	testing.expect(t,scroll_test_layout(&ctx,{pointer=button_point}),"Ordinary buttons still accept a fresh click after dragging")
}

@(test)
scroll_blocking_and_focus_reset_cancel_drag_without_a_later_click :: proc(t:^testing.T) {
	ctx:Context; testing.expect(t,init(&ctx,measure=scroll_test_measure)); defer destroy(&ctx)
	ctx.style.height=30
	scroll_test_layout(&ctx); scroll_test_layout(&ctx)
	thumb,found:=scroll_test_bar_bounds(&ctx,1,true); testing.expect(t,found)
	scroll_test_layout(&ctx,{pointer=scroll_test_center(thumb),pointer_down=true})
	testing.expect(t,ctx.scroll_drag_id!=0)
	before:=scroll_test_data(&ctx).position
	button_point,button_found:=scroll_test_visible_button(&ctx); testing.expect(t,button_found)
	testing.expect(t,!scroll_test_layout(&ctx,{pointer=button_point,pointer_down=true,scroll={0,-1},blocked=true}))
	testing.expect(t,ctx.scroll_drag_id==0 && scroll_test_data(&ctx).position==before,"Console or focus blocking stops both dragging and wheel input")
	testing.expect(t,!scroll_test_layout(&ctx,{pointer=button_point,pointer_down=true}))
	testing.expect(t,!scroll_test_layout(&ctx,{pointer=button_point}),"Unblocking and releasing an old held press must not click a widget")
	thumb,found=scroll_test_bar_bounds(&ctx,1,true); testing.expect(t,found)
	scroll_test_layout(&ctx,{pointer=scroll_test_center(thumb),pointer_down=true})
	testing.expect(t,ctx.scroll_drag_id!=0)
	reset_focus(&ctx)
	testing.expect(t,ctx.scroll_drag_id==0 && ctx.active_id==0,"Closing or reopening a modal resets scrollbar ownership")
	testing.expect(t,!scroll_test_layout(&ctx,{pointer=button_point}))
}

@(test)
scroll_both_axes_resize_and_non_overflowing_content_keep_valid_layout :: proc(t:^testing.T) {
	ctx:Context; testing.expect(t,init(&ctx,measure=scroll_test_measure)); defer destroy(&ctx)
	ctx.style.height=30
	scroll_test_layout(&ctx,horizontal=true); scroll_test_layout(&ctx,horizontal=true)
	scroll_test_layout(&ctx,{pointer={40,40},scroll={-1,-1}},horizontal=true)
	testing.expect(t,scroll_test_data(&ctx).position==[2]f32{-60,-60},"A two-axis viewport supports independent wheel offsets")
	horizontal_track,horizontal_found:=scroll_test_bar_bounds(&ctx,0); testing.expect(t,horizontal_found)
	scroll_test_layout(&ctx,{pointer=scroll_test_center(horizontal_track),scroll={0,-1}},horizontal=true)
	testing.expect(t,scroll_test_data(&ctx).position==[2]f32{-120,-60},"A vertical wheel over the horizontal gutter scrolls that axis only")
	horizontal_thumb,thumb_found:=scroll_test_bar_bounds(&ctx,0,true); testing.expect(t,thumb_found)
	scroll_test_layout(&ctx,{pointer=scroll_test_center(horizontal_thumb),pointer_down=true},horizontal=true)
	scroll_test_layout(&ctx,{pointer={horizontal_track.x-50,horizontal_track.y+horizontal_track.height*0.5},pointer_down=true},horizontal=true)
	testing.expect(t,scroll_test_data(&ctx).position==[2]f32{0,-60},"Horizontal dragging clamps at the start without changing the vertical offset")
	testing.expect(t,!scroll_test_layout(&ctx,{pointer={40,40}},horizontal=true))
	for axis in 0..<2 {
		track,track_found:=scroll_test_bar_bounds(&ctx,axis)
		thumb,thumb_found:=scroll_test_bar_bounds(&ctx,axis,true)
		testing.expect(t,track_found && thumb_found && thumb.x>=track.x && thumb.y>=track.y &&
			thumb.x+thumb.width<=track.x+track.width+0.01 && thumb.y+thumb.height<=track.y+track.height+0.01)
	}
	for _ in 0..<2 {scroll_test_layout(&ctx,horizontal=true,size={350,200})}
	for axis in 0..<2 {
		track,track_found:=scroll_test_bar_bounds(&ctx,axis)
		thumb,thumb_found:=scroll_test_bar_bounds(&ctx,axis,true)
		testing.expect(t,track_found && thumb_found && thumb.x>=track.x && thumb.y>=track.y &&
			thumb.x+thumb.width<=track.x+track.width+0.01 && thumb.y+thumb.height<=track.y+track.height+0.01,
			"Resizing keeps rendered thumbs inside their actual tracks")
	}
	for _ in 0..<2 {scroll_test_layout(&ctx,horizontal=true,size={160,80})}
	data:=scroll_test_data(&ctx)
	testing.expect(t,data.viewport.width>0 && data.viewport.height>0 && data.position[0]<=0 && data.position[1]<=0)
	for _ in 0..<3 {scroll_test_layout(&ctx,size={220,200},count=2)}
	testing.expect(t,!scroll_test_thumb_drawn(&ctx,1) && scroll_test_data(&ctx).position==[2]f32{},"Content that fits has no visible thumb and clears stale offsets")
}

scroll_test_nested_layout :: proc(ctx:^Context,controls:Inputs={}) -> bool {
	assert(begin(ctx,{500,400},controls,1.0/60))
	panel(ctx,"root",{layout={sizing={width=grow({}),height=grow({})},layoutDirection=.TopToBottom}})
	scroll_panel(ctx,"outer",{layout={sizing={width=fixed(240),height=fixed(140)},layoutDirection=.TopToBottom}},false,true)
	panel(ctx,"spacer",{layout={sizing={width=grow({}),height=fixed(80)}}}); end_panel(ctx)
	scroll_panel(ctx,"inner",{layout={sizing={width=fixed(180),height=fixed(130)},layoutDirection=.TopToBottom}},false,true)
	clicked:=scroll_test_rows(ctx,20)
	end_panel(ctx); end_panel(ctx); end_panel(ctx)
	assert(finish(ctx))
	return clicked
}

@(test)
scroll_nested_gutters_remain_clipped_and_unclickable_outside_the_outer_viewport :: proc(t:^testing.T) {
	ctx:Context; testing.expect(t,init(&ctx,measure=scroll_test_measure)); defer destroy(&ctx)
	ctx.style.height=30
	scroll_test_nested_layout(&ctx); scroll_test_nested_layout(&ctx)
	outer,outer_found:=bounds(&ctx,"outer")
	track,track_found:=scroll_test_bar_bounds(&ctx,1,id="inner")
	testing.expect(t,outer_found && track_found && track.y<outer.y+outer.height && track.y+track.height>outer.y+outer.height,
		"The fixture partly clips a nested scrollbar, exercising ancestor clipping")
	clips:[16]rl.Rectangle
	depth:=0; rendered:=false
	track_id:=scroll_track_id(clay.ID("inner").id,1).id
	for command in ctx.commands.internalArray[:ctx.commands.length] {
		b:=command.boundingBox
		box:=rl.Rectangle{b.x,b.y,b.width,b.height}
		if command.commandType==.ScissorStart {
			if depth>0 {box=intersect(box,clips[depth-1])}
			clips[depth]=box; depth+=1
		} else if command.commandType==.ScissorEnd {depth-=1}
		else if command.commandType==.Rectangle && command.id==track_id {
			rendered=true
			testing.expect(t,depth>0 && clips[depth-1].y+clips[depth-1].height<=outer.y+outer.height+0.01,
				"The actual Clay render command keeps the nested track inside its outer clip")
		}
	}
	testing.expect(t,rendered && depth==0)
	outside:=[2]f32{track.x+track.width*0.5,outer.y+outer.height+10}
	testing.expect(t,!scroll_test_nested_layout(&ctx,{pointer=outside,pointer_down=true}))
	testing.expect(t,ctx.scroll_drag_id==0,"A clipped part of the track cannot capture a pointer press")
	scroll_test_nested_layout(&ctx,{pointer=outside})
	thumb,thumb_found:=scroll_test_bar_bounds(&ctx,1,true,"inner"); testing.expect(t,thumb_found)
	scroll_test_nested_layout(&ctx,{pointer=scroll_test_center(thumb),pointer_down=true})
	testing.expect(t,ctx.scroll_drag_id==clay.ID("inner").id,"The visible part of a nested track remains usable")
	testing.expect(t,!scroll_test_nested_layout(&ctx,{pointer=outside}))
}

@(test)
scroll_fit_constrained_panel_retains_its_intrinsic_content_and_bounds :: proc(t:^testing.T) {
	ctx:Context; testing.expect(t,init(&ctx,measure=scroll_test_measure)); defer destroy(&ctx)
	ctx.style.height=30
	for _ in 0..<2 {scroll_test_layout(&ctx,fit_height=true)}
	data:=scroll_test_data(&ctx)
	testing.expect(t,data.found && data.viewport.height>0 && data.viewport.height<=120 && data.content.height>data.viewport.height,
		"Fit-constrained menus retain a visible bounded viewport rather than collapsing")
	thumb,found:=scroll_test_bar_bounds(&ctx,1,true)
	testing.expect(t,found && thumb.width>0 && thumb.height>0)
	scroll_test_layout(&ctx,{pointer={40,40},scroll={0,-1}},fit_height=true)
	testing.expect(t,scroll_test_data(&ctx).position[1]==-60)
}

scroll_test_footer_layout :: proc(ctx:^Context,controls:Inputs={}) {
	assert(begin(ctx,{320,300},controls,1.0/60))
	panel(ctx,"root",{layout={sizing={width=grow({}),height=grow({})},layoutDirection=.TopToBottom,padding=padding(8),childGap=7}})
	panel(ctx,"header",{layout={sizing={width=grow({}),height=fixed(40)}}}); label(ctx,"Palette",ctx.style.text); end_panel(ctx)
	scroll_panel(ctx,"list",{layout={sizing={width=fixed(220),height=fixed(100)},layoutDirection=.TopToBottom,childGap=7}},false,true)
	scroll_test_rows(ctx,20)
	end_panel(ctx)
	panel(ctx,"footer",{layout={sizing={width=grow({}),height=fixed(50)}}}); label(ctx,"Pinned floor controls",ctx.style.text); end_panel(ctx)
	end_panel(ctx); assert(finish(ctx))
}

@(test)
scroll_fixed_height_palette_keeps_its_sibling_footer_visible :: proc(t:^testing.T) {
	ctx:Context; testing.expect(t,init(&ctx,measure=scroll_test_measure)); defer destroy(&ctx)
	ctx.style.height=30
	scroll_test_footer_layout(&ctx)
	viewport,viewport_found:=bounds(&ctx,"list")
	footer,footer_found:=bounds(&ctx,"footer")
	testing.expect(t,viewport_found && footer_found && viewport.height>30 && viewport.height<=100.01 &&
		viewport.y+viewport.height<=footer.y+0.01,"Wrapping a fixed-height scroll panel must not let its viewport cover the pinned sibling footer")
	point:=scroll_test_center(viewport)
	scroll_test_footer_layout(&ctx,{pointer=point,scroll={0,-1000}})
	viewport_after,_:=bounds(&ctx,"list"); footer_after,_:=bounds(&ctx,"footer")
	testing.expect(t,viewport_after==viewport && footer_after==footer,"Scrolling the palette changes only its contents, leaving footer and viewport fixed")
	data:=scroll_test_data(&ctx)
	testing.expect(t,data.position[1]==-max(data.content.height-data.viewport.height,0))
}
