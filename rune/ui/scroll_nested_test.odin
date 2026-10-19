package ui

import "core:testing"
import "core:fmt"
import clay "../../third_party/clay/clay-odin"

@(private)
scroll_many_fields_layout :: proc(ctx:^Context,fields:[]Text_Field,size:[2]f32,controls:Inputs={}) -> bool {
	if !begin(ctx,size,controls,1.0/60) {return false}
	panel(ctx,"many_fields_root",{layout={sizing={width=grow({}),height=grow({})},layoutDirection=.TopToBottom,childGap=8}})
	scroll_panel(ctx,"many_fields_list",{layout={sizing={width=fixed(220),height=fixed(120)},layoutDirection=.TopToBottom,childGap=4}},false,true)
	for &field,index in fields {text_input(ctx,fmt.tprintf("many_fields_%d",index),&field)}
	end_panel(ctx)
	button(ctx,"many_fields_save","Save")
	end_panel(ctx)
	return finish(ctx)
}

@(test)
scroll_inspector_supports_many_clipped_text_fields_without_native_capacity_errors :: proc(t:^testing.T) {
	ctx:Context
	if !testing.expect(t,init(&ctx,measure=scroll_test_measure)) {return}
	defer destroy(&ctx)
	ctx.style.height=30;ctx.style.font_size=14
	fields:[24]Text_Field
	for &field in fields[:] {text_field_set(&field,"0.25")}
	for size in ([3][2]f32{{360,360},{800,540},{1280,720}}) {
		// All 24 inputs clip their text, in addition to the inspector viewport.
		// Repeat with fewer fields to exercise persistent-container pruning too.
		for count in ([3]int{24,12,24}) {
			testing.expect(t,scroll_many_fields_layout(&ctx,fields[:count],size),last_error(&ctx))
			for index in 0..<count {
				testing.expect(t,scroll_test_data(&ctx,fmt.tprintf("many_fields_%d",index)).found,
					"each text field retains its native clip/scroll data")
			}
			footer,found:=bounds(&ctx,"many_fields_save")
			testing.expect(t,found && footer.y>=0 && footer.y+footer.height<=size[1],"inspector footer remains accessible")
		}
	}
	box,found:=bounds(&ctx,"many_fields_0")
	if !testing.expect(t,found) {return}
	point:=scroll_test_center(box)
	testing.expect(t,scroll_many_fields_layout(&ctx,fields[:],{1280,720},{pointer=point,scroll={0,-1}}),last_error(&ctx))
	testing.expect(t,scroll_test_data(&ctx,"many_fields_list").position[1]==-60,
		"vertical wheel input over a clipped numeric field still scrolls its inspector")
}

scroll_test_field_layout :: proc(ctx:^Context,field:^Text_Field,controls:Inputs={}) {
	assert(begin(ctx,{500,400},controls,1.0/60))
	panel(ctx,"root",{layout={sizing={width=grow({}),height=grow({})},layoutDirection=.TopToBottom}})
	scroll_panel(ctx,"list",{layout={sizing={width=fixed(220),height=fixed(120)},layoutDirection=.TopToBottom}},false,true)
	text_input(ctx,"field",field)
	scroll_test_rows(ctx,20)
	end_panel(ctx);end_panel(ctx);assert(finish(ctx))
}

@(test)
scroll_wheel_over_a_clipped_text_field_routes_each_axis_to_its_overflowing_viewport :: proc(t:^testing.T) {
	ctx:Context;testing.expect(t,init(&ctx,measure=scroll_test_measure));defer destroy(&ctx)
	ctx.style.height=30;ctx.style.font_size=14
	field:Text_Field
	testing.expect(t,text_field_set(&field,"a-very-long-authored-file-name-that-does-not-fit-in-the-visible-text-field-width"))
	scroll_test_field_layout(&ctx,&field);scroll_test_field_layout(&ctx,&field)
	box,found:=bounds(&ctx,"field");testing.expect(t,found)
	point:=scroll_test_center(box)
	scroll_test_field_layout(&ctx,&field,{pointer=point})
	before:=scroll_test_data(&ctx,"field")
	testing.expect(t,before.found && before.content.width>before.viewport.width && before.content.height<=before.viewport.height,"the actual text field clips horizontal content without vertical overflow")
	scroll_test_field_layout(&ctx,&field,{pointer=point,scroll={-1,-1}})
	scroll_test_field_layout(&ctx,&field,{pointer=point})
	testing.expect(t,scroll_test_data(&ctx).position[1]==-60,"vertical wheel input over the text field reaches the overflowing outer inspector")
	testing.expect(t,scroll_test_data(&ctx,"field").position==[2]f32{-60,0},"horizontal wheel input still belongs to the text field")
	testing.expect(t,text_field_text(&field)=="a-very-long-authored-file-name-that-does-not-fit-in-the-visible-text-field-width" && !field.active,"scrolling cannot activate or edit the field")
}

scroll_test_text_x :: proc(ctx:^Context,value:string) -> (f32,bool) {
	for command in ctx.commands.internalArray[:ctx.commands.length] {
		if command.commandType!=.Text {continue}
		text:=command.renderData.text.stringContents
		if string(text.chars[:text.length])==value {return command.boundingBox.x,true}
	}
	return 0,false
}

@(test)
scroll_horizontal_text_field_wheel_moves_visible_text_and_activation_exposes_the_caret :: proc(t:^testing.T) {
	ctx:Context;testing.expect(t,init(&ctx,measure=scroll_test_measure));defer destroy(&ctx)
	ctx.style.height=30;ctx.style.font_size=14
	field:Text_Field
	value:="a-very-long-authored-file-name-that-does-not-fit-in-the-visible-text-field-width"
	testing.expect(t,text_field_set(&field,value))
	scroll_test_field_layout(&ctx,&field);scroll_test_field_layout(&ctx,&field)
	box,found:=bounds(&ctx,"field");testing.expect(t,found);point:=scroll_test_center(box)
	scroll_test_field_layout(&ctx,&field,{pointer=point})
	before,before_found:=scroll_test_text_x(&ctx,value);testing.expect(t,before_found)
	scroll_test_field_layout(&ctx,&field,{pointer=point,scroll={-1,0}})
	scroll_test_field_layout(&ctx,&field,{pointer=point})
	after,after_found:=scroll_test_text_x(&ctx,value)
	testing.expect(t,after_found && abs((before-after)-60)<0.01 && scroll_test_data(&ctx).position==[2]f32{},"horizontal scrolling moves the actual clipped text without scrolling its inspector")
	scroll_test_field_layout(&ctx,&field,{pointer=point,activate=true})
	scroll_test_field_layout(&ctx,&field,{pointer=point})
	testing.expect(t,field.active && field.cursor==field.length && scroll_test_data(&ctx,"field").position[0]==0,"entering text editing resets wheel offset so the caret slice remains visible")
}

scroll_test_fitting_nested_layout :: proc(ctx:^Context,controls:Inputs={}) {
	assert(begin(ctx,{500,400},controls,1.0/60))
	panel(ctx,"root",{layout={sizing={width=grow({}),height=grow({})},layoutDirection=.TopToBottom}})
	scroll_panel(ctx,"outer",{layout={sizing={width=fixed(240),height=fixed(120)},layoutDirection=.TopToBottom}},false,true)
	scroll_panel(ctx,"inner",{layout={sizing={width=fixed(180),height=fixed(100)},layoutDirection=.TopToBottom}},false,true)
	scroll_test_rows(ctx,2)
	end_panel(ctx)
	panel(ctx,"spacer",{layout={sizing={width=grow({}),height=fixed(200)}}});end_panel(ctx)
	end_panel(ctx);end_panel(ctx);assert(finish(ctx))
}

@(test)
scroll_fitting_nested_panels_pass_the_wheel_to_their_overflowing_ancestor :: proc(t:^testing.T) {
	ctx:Context;testing.expect(t,init(&ctx,measure=scroll_test_measure));defer destroy(&ctx)
	ctx.style.height=30
	scroll_test_fitting_nested_layout(&ctx);scroll_test_fitting_nested_layout(&ctx)
	box,found:=bounds(&ctx,"inner");testing.expect(t,found)
	point:=scroll_test_center(box)
	scroll_test_fitting_nested_layout(&ctx,{pointer=point})
	testing.expect(t,scroll_test_data(&ctx,"inner").content.height<=scroll_test_data(&ctx,"inner").viewport.height)
	scroll_test_fitting_nested_layout(&ctx,{pointer=point,scroll={0,-1}})
	scroll_test_fitting_nested_layout(&ctx,{pointer=point})
	testing.expect(t,scroll_test_data(&ctx,"outer").position[1]==-60 && scroll_test_data(&ctx,"inner").position==[2]f32{},"a fitting nested viewport cannot swallow vertical wheel input")
}

@(test)
scroll_overflowing_nested_panels_keep_their_own_wheel_and_respect_ancestor_clipping :: proc(t:^testing.T) {
	ctx:Context;testing.expect(t,init(&ctx,measure=scroll_test_measure));defer destroy(&ctx)
	ctx.style.height=30
	scroll_test_nested_layout(&ctx);scroll_test_nested_layout(&ctx)
	point:=[2]f32{40,100}
	scroll_test_nested_layout(&ctx,{pointer=point})
	scroll_test_nested_layout(&ctx,{pointer=point,scroll={0,-1}})
	scroll_test_nested_layout(&ctx,{pointer=point})
	testing.expect(t,scroll_test_data(&ctx,"inner").position[1]==-60 && scroll_test_data(&ctx,"outer").position==[2]f32{},"a genuinely overflowing inner panel consumes its wheel without scrolling its ancestor")
	outside:=[2]f32{40,170}
	scroll_test_nested_layout(&ctx,{pointer=outside})
	scroll_test_nested_layout(&ctx,{pointer=outside,scroll={0,-1}})
	scroll_test_nested_layout(&ctx,{pointer=outside})
	testing.expect(t,scroll_test_data(&ctx,"inner").position[1]==-60 && scroll_test_data(&ctx,"outer").position==[2]f32{},"clipped inner content outside its ancestor cannot receive wheel input")
	previous:=clay.GetCurrentContext();clay.SetCurrentContext(ctx.native)
	testing.expect(t,!clay.PointerOver(clay.ID("inner")))
	clay.SetCurrentContext(previous)
}
