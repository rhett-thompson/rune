package ui

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"

text_area_test_layout :: proc(ctx:^Context,area:^Text_Area,controls:Inputs={},wrap:bool=false,size:=[2]f32{400,250}) -> Text_Input_Result {
	assert(begin(ctx,size,controls,1.0/60))
	panel(ctx,"root",{layout={sizing={width=grow({}),height=grow({})},layoutDirection=.TopToBottom}})
	result:=text_area(ctx,"area",area,height=140,wrap=wrap)
	button(ctx,"next","Next")
	end_panel(ctx); assert(finish(ctx))
	return result
}

@(test)
text_area_roundtrips_long_unicode_paragraphs_and_normalizes_clipboard_line_endings :: proc(t:^testing.T) {
	area:Text_Area
	testing.expect(t,text_area_set(&area,"café\r\n中\t☃\rfinal"))
	testing.expect_value(t,text_area_text(&area),"café\n中\t☃\nfinal")
	large:[8192]u8; for &byte in large[:] {byte='a'}
	testing.expect(t,text_area_set(&area,string(large[:])))
	testing.expect_value(t,area.length,8192)
	testing.expect_value(t,text_area_text(&area),string(large[:]))
	area.anchor=0
	testing.expect(t,text_area_insert(&area,"First paragraph.\n\nSecond paragraph: α and 中."))
	testing.expect_value(t,text_area_text(&area),"First paragraph.\n\nSecond paragraph: α and 中.")
	testing.expect(t,utf8.valid_string(text_area_text(&area)))
}

@(test)
text_area_overflow_and_invalid_pastes_preserve_the_value_cursor_and_selection :: proc(t:^testing.T) {
	area:Text_Area; text_area_set(&area,"old\nvalue"); area.anchor=0
	before:=area
	too_long:[8193]u8; for &byte in too_long[:] {byte='a'}
	for value in ([4]string{string(too_long[:]),"\xff","bad\x00tail","bad\x1btail"}) {
		testing.expect(t,!text_area_insert(&area,value))
		testing.expect(t,area==before,"Rejected paste cannot lose the selected old text or truncate the replacement")
		testing.expect(t,!text_area_set(&area,value))
		testing.expect(t,area==before)
	}
	testing.expect(t,text_area_insert(&area,string(too_long[:8192])))
	full:=area
	testing.expect(t,!text_area_insert(&area,"é"))
	testing.expect(t,area==full,"Overcapacity insertion at the caret leaves the full body intact")
}

@(test)
text_area_unicode_selection_and_deletion_never_split_a_rune :: proc(t:^testing.T) {
	area:Text_Area; text_area_set(&area,"α\n中☃")
	text_area_move(&area,.Left,true)
	testing.expect_value(t,string(area.buffer[min(area.cursor,area.anchor):max(area.cursor,area.anchor)]),"☃")
	testing.expect(t,text_area_insert(&area,"雪\nend"))
	testing.expect_value(t,text_area_text(&area),"α\n中雪\nend")
	text_area_move(&area,.Home); text_area_move(&area,.Left)
	testing.expect(t,text_area_delete(&area,true))
	testing.expect_value(t,text_area_text(&area),"α\n中\nend")
	text_area_move(&area,.Home); text_area_move(&area,.Right)
	testing.expect(t,text_area_delete(&area,false))
	testing.expect_value(t,text_area_text(&area),"α\n中end")
	testing.expect(t,utf8.valid_string(text_area_text(&area)))
	area.anchor=0; area.cursor=area.length
	testing.expect(t,text_area_delete(&area,false))
	testing.expect(t,area.length==0 && area.cursor==0 && area.anchor==0)
}

@(test)
text_area_vertical_movement_preserves_a_unicode_column_across_short_lines :: proc(t:^testing.T) {
	area:Text_Area; text_area_set(&area,"αβγδε\nx\n中雪☃abcd")
	text_area_move(&area,.Document_Start); for _ in 0..<4 {text_area_move(&area,.Right)}
	testing.expect_value(t,area.cursor,8)
	text_area_move(&area,.Down)
	testing.expect_value(t,area.cursor,12)
	text_area_move(&area,.Down)
	testing.expect_value(t,string(area.buffer[13:area.cursor]),"中雪☃a")
	text_area_move(&area,.Up); text_area_move(&area,.Up)
	testing.expect_value(t,area.cursor,8)
	text_area_move(&area,.End,true)
	testing.expect_value(t,string(area.buffer[area.anchor:area.cursor]),"ε")
	text_area_move(&area,.Document_End)
	testing.expect(t,area.cursor==area.length && area.anchor==area.length)
}

@(test)
text_area_activation_modal_and_focus_transfer_preserve_owned_text :: proc(t:^testing.T) {
	ctx:Context; testing.expect(t,init(&ctx,measure=text_test_measure)); defer destroy(&ctx)
	area:Text_Area; text_area_set(&area,"First.\nSecond.")
	text_area_test_layout(&ctx,&area)
	testing.expect(t,!area.active,"Initial focus alone cannot capture text input")
	result:=text_area_test_layout(&ctx,&area,{activate=true})
	testing.expect(t,area.active && !result.committed && !result.changed)
	result=text_area_test_layout(&ctx,&area,{blocked=true,activate=true,cancel=true})
	testing.expect(t,area.active && !result.committed && !result.canceled)
	result=text_area_test_layout(&ctx,&area,{cancel=true})
	testing.expect(t,!area.active && result.canceled)
	text_area_test_layout(&ctx,&area,{activate=true})
	result=text_area_test_layout(&ctx,&area,{next=true})
	testing.expect(t,!area.active && result.committed && focused(&ctx,"next"))
	testing.expect_value(t,text_area_text(&area),"First.\nSecond.")
	text_area_test_layout(&ctx,&area,{previous=true})
	text_area_test_layout(&ctx,&area,{activate=true})
	result=text_area_test_layout(&ctx,&area,{activate=true})
	testing.expect(t,!area.active && result.committed,"Controller/custom accept commits; native Enter is reserved for paragraphs")
}

@(test)
text_area_native_layout_scrolls_both_axes_and_reveals_the_active_caret :: proc(t:^testing.T) {
	ctx:Context; testing.expect(t,init(&ctx,measure=text_test_measure)); defer destroy(&ctx)
	ctx.style.font_size=14
	body:=strings.repeat("Long body line with many words that continues well past the narrow editor viewport.\n",40); defer delete(body)
	area:Text_Area; testing.expect(t,text_area_set(&area,body))
	text_area_test_layout(&ctx,&area); text_area_test_layout(&ctx,&area)
	data:=scroll_test_data(&ctx,"area")
	testing.expect(t,data.found && data.content.height>data.viewport.height && data.content.width>data.viewport.width)
	box,found:=bounds(&ctx,"area"); testing.expect(t,found); point:=scroll_test_center(box)
	text_area_test_layout(&ctx,&area,{pointer=point,scroll={-1,-1}})
	testing.expect(t,scroll_test_data(&ctx,"area").position==[2]f32{-60,-60})
	text_area_test_layout(&ctx,&area,{pointer=point,activate=true}); text_area_test_layout(&ctx,&area,{pointer=point})
	data=scroll_test_data(&ctx,"area")
	caret,has_caret:=bounds(&ctx,"area_caret")
	testing.expect(t,area.active && has_caret)
	testing.expect(t,caret.y>=box.y && caret.y+caret.height<=box.y+box.height && caret.x>=box.x && caret.x+caret.width<=box.x+box.width,"Activating a long document reveals its real caret inside the clipping viewport")
	text_area_move(&area,.Document_Start); text_area_test_layout(&ctx,&area,{pointer=point})
	testing.expect(t,scroll_test_data(&ctx,"area").position==[2]f32{},"Keyboard cursor movement reveals the first paragraph")
	text_area_test_layout(&ctx,&area,{pointer=point,scroll={0,-1}})
	text_area_test_layout(&ctx,&area,{pointer=point})
	testing.expect_value(t,scroll_test_data(&ctx,"area").position[1],f32(-60))
	testing.expect_value(t,text_area_text(&area),body)
	text_area_move(&area,.Document_End); text_area_move(&area,.Up); text_area_move(&area,.End)
	text_area_test_layout(&ctx,&area,{pointer=point}); text_area_test_layout(&ctx,&area,{pointer=point})
	caret,has_caret=bounds(&ctx,"area_caret")
	testing.expect(t,has_caret && caret.x>=box.x && caret.x+caret.width<=box.x+box.width && caret.y>=box.y && caret.y+caret.height<=box.y+box.height,"Horizontal caret movement scrolls the actual long line into view")
	testing.expect(t,scroll_test_thumb_drawn(&ctx,0,"area") && scroll_test_thumb_drawn(&ctx,1,"area"))
}

@(test)
text_area_virtualizes_thousands_of_blank_lines_without_exhausting_clay :: proc(t:^testing.T) {
	ctx:Context; testing.expect(t,init(&ctx,measure=text_test_measure)); defer destroy(&ctx)
	ctx.style.font_size=14
	area:Text_Area; blank:[8192]u8; for &byte in blank[:] {byte='\n'}
	testing.expect(t,text_area_set(&area,string(blank[:])))
	text_area_test_layout(&ctx,&area); text_area_test_layout(&ctx,&area)
	testing.expect(t,ctx.commands.length<150,"A full document keeps a bounded number of visible render commands")
	testing.expect(t,scroll_test_data(&ctx,"area").content.height>160000)
	text_area_test_layout(&ctx,&area,{activate=true}); text_area_test_layout(&ctx,&area)
	caret,found:=bounds(&ctx,"area_caret"); viewport,_:=bounds(&ctx,"area")
	testing.expect(t,found && caret.y>=viewport.y && caret.y+caret.height<=viewport.y+viewport.height)
	testing.expect(t,last_error(&ctx)=="")
}

@(test)
text_area_pointer_release_positions_the_caret_in_a_scrolled_unicode_line :: proc(t:^testing.T) {
	ctx:Context; testing.expect(t,init(&ctx,measure=text_test_measure)); defer destroy(&ctx)
	ctx.style.font_size=14
	area:Text_Area; text_area_set(&area,"αβ\nsecond\nthird")
	text_area_test_layout(&ctx,&area); text_area_test_layout(&ctx,&area)
	box,_:=bounds(&ctx,"area")
	point:=[2]f32{box.x+8,box.y+8+20+4}
	text_area_test_layout(&ctx,&area,{pointer=point,pointer_down=true})
	text_area_test_layout(&ctx,&area,{pointer=point})
	testing.expect(t,area.active && area.cursor==5 && area.anchor==5,fmt.tprintf("Click starts the second UTF-8 line at byte five, got %d",area.cursor))
}

@(test)
text_area_wrap_keeps_words_and_utf8_offsets :: proc(t:^testing.T) {
	ctx:Context; testing.expect(t,init(&ctx,measure=text_test_measure)); defer destroy(&ctx)
	ctx.style.font_size=2
	body:="alpha beta gamma\n\n雪雪雪雪"
	area:Text_Area; testing.expect(t,text_area_set(&area,body))
	storage:[16]Text_Area_Line
	lines:=text_area_lines(&area,&ctx,10,storage[:])
	if !testing.expect(t,len(lines)==5) {return}
	testing.expect(t,lines[0]==(Text_Area_Line{0,11,10}) && body[lines[1].start:lines[1].end]=="gamma")
	testing.expect(t,lines[2].start==lines[2].end && lines[2].start==17,"An explicit blank line is preserved")
	testing.expect(t,body[lines[3].start:lines[3].end]=="雪雪雪" && body[lines[4].start:lines[4].end]=="雪")
	area.cursor=2
	text_area_move_wrapped(&area,lines,.End,false)
	testing.expect(t,area.cursor==11 && text_area_caret_line(lines,area.cursor,area.soft_line_end)==0,"End keeps a shared byte offset on the visual row it came from")
	text_area_move_wrapped(&area,lines,.Down,true)
	testing.expect(t,area.cursor==16 && area.anchor==11)
	text_area_move_wrapped(&area,lines,.Up,false)
	testing.expect(t,area.cursor==11 && text_area_caret_line(lines,area.cursor,area.soft_line_end)==0)
	testing.expect_value(t,text_area_text(&area),body)
}

@(test)
text_area_wrapped_layout_reflows_and_keeps_the_clicked_row :: proc(t:^testing.T) {
	ctx:Context; testing.expect(t,init(&ctx,measure=text_test_measure)); defer destroy(&ctx)
	ctx.style.font_size=14
	body:=strings.repeat("Long lines wrap at the available width of the text area. ",16); defer delete(body)
	area:Text_Area; testing.expect(t,text_area_set(&area,body))
	// The second frame wraps at the first completed viewport width. The
	// scrollbar uses the wrapped content measurements on the following frame.
	for _ in 0..<3 {text_area_test_layout(&ctx,&area,wrap=true)}
	wide:=scroll_test_data(&ctx,"area")
	testing.expect(t,wide.found && wide.content.height>wide.viewport.height && wide.content.width<=wide.viewport.width+0.1)
	testing.expect(t,!scroll_test_thumb_drawn(&ctx,0,"area"),"Wrapped text has no horizontal scrollbar")
	testing.expect(t,scroll_test_thumb_drawn(&ctx,1,"area"),"Tall wrapped text keeps its vertical scrollbar")
	size:=[2]f32{240,250}
	text_area_test_layout(&ctx,&area,wrap=true,size=size); text_area_test_layout(&ctx,&area,wrap=true,size=size)
	narrow:=scroll_test_data(&ctx,"area")
	testing.expect(t,narrow.viewport.width<wide.viewport.width && narrow.content.height>wide.content.height && narrow.content.width<=narrow.viewport.width+0.1)
	box,found:=bounds(&ctx,"area"); testing.expect(t,found)
	point:=[2]f32{box.x+box.width-4,box.y+16}
	text_area_test_layout(&ctx,&area,{pointer=point,pointer_down=true},wrap=true,size=size)
	text_area_test_layout(&ctx,&area,{pointer=point},wrap=true,size=size)
	text_area_test_layout(&ctx,&area,{pointer=point},wrap=true,size=size)
	caret,has_caret:=bounds(&ctx,"area_caret")
	testing.expect(t,area.active && area.soft_line_end && has_caret && caret.y<box.y+28,"Clicking past the text on the first wrapped row leaves the caret on that row")
	testing.expect_value(t,text_area_text(&area),body)
}
