package ui

import "core:testing"
import "core:unicode/utf8"

text_test_measure :: proc(text:string,size,spacing:f32) -> [2]f32 {return {f32(len(text))*size*0.5,size}}

text_test_layout :: proc(ctx:^Context,field:^Text_Field,controls:Inputs) -> Text_Input_Result {
	assert(begin(ctx,{400,200},controls,1.0/60))
	panel(ctx,"root",{layout={sizing={width=grow({}),height=grow({})},layoutDirection=.TopToBottom}})
	result:=text_input(ctx,"field",field)
	button(ctx,"next","Next")
	end_panel(ctx)
	assert(finish(ctx))
	return result
}

@(test)
text_field_activation_focus_and_modal_ownership :: proc(t:^testing.T) {
	ctx:Context
	testing.expect(t,init(&ctx,measure=text_test_measure))
	defer destroy(&ctx)
	f:Text_Field
	text_field_set(&f,"name")
	text_test_layout(&ctx,&f,{})
	testing.expect(t,!f.active,"Initial focus does not capture typing")
	r:=text_test_layout(&ctx,&f,{activate=true})
	testing.expect(t,f.active && !r.committed)
	r=text_test_layout(&ctx,&f,{blocked=true,activate=true,cancel=true})
	testing.expect(t,f.active && !r.committed && !r.canceled,"A modal retains field state without editing")
	r=text_test_layout(&ctx,&f,{cancel=true})
	testing.expect(t,!f.active && r.canceled)
	text_test_layout(&ctx,&f,{activate=true})
	r=text_test_layout(&ctx,&f,{activate=true})
	testing.expect(t,!f.active && r.committed)
	text_test_layout(&ctx,&f,{activate=true})
	r=text_test_layout(&ctx,&f,{next=true})
	testing.expect(t,!f.active && r.committed,"Tab commits on focus transfer")
	testing.expect(t,focused(&ctx,"next"))
}

@(test)
text_field_unicode_edit_and_selection :: proc(t:^testing.T) {
	f:Text_Field
	testing.expect(t,text_field_set(&f,"café"))
	testing.expect(t,text_field_delete(&f,true))
	testing.expect_value(t,text_field_text(&f),"caf")
	testing.expect(t,text_field_insert(&f,"中"))
	testing.expect(t,utf8.valid_string(text_field_text(&f)))
	f.cursor=3
	testing.expect(t,text_field_delete(&f,false))
	testing.expect_value(t,text_field_text(&f),"caf")
	f.select_all=true
	testing.expect(t,text_field_insert(&f,"door α"))
	testing.expect_value(t,text_field_text(&f),"door α")
	f.cursor=4
	testing.expect(t,text_field_insert(&f,"way"))
	testing.expect_value(t,text_field_text(&f),"doorway α")
}

@(test)
text_field_rejects_invalid_paste_atomically :: proc(t:^testing.T) {
	f:Text_Field
	text_field_set(&f,"old value"); f.select_all=true
	testing.expect(t,!text_field_insert(&f,"two\nlines"))
	testing.expect(t,!text_field_insert(&f,"\xff"))
	testing.expect_value(t,text_field_text(&f),"old value")
	testing.expect(t,f.select_all)
	large:[1025]u8; for &b in large[:] {b='a'}
	testing.expect(t,!text_field_insert(&f,string(large[:])))
	testing.expect(t,text_field_insert(&f,string(large[:1024])))
	testing.expect(t,!text_field_insert(&f,"b"))
	testing.expect_value(t,f.length,1024)
	f.select_all=true
	testing.expect(t,text_field_delete(&f,true))
	testing.expect_value(t,f.length,0)
}
