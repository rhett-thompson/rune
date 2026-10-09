package ui

import "core:unicode"
import "core:unicode/utf8"
import "core:fmt"
import clay "../../third_party/clay/clay-odin"
import rl "vendor:raylib"

// Caller-owned single-line UTF-8 editing state. No heap ownership; text() is
// borrowed until the next edit. Activation is explicit so focused fields do not
// consume application shortcuts merely because they are the first widget.
Text_Field :: struct {
	buffer: [1024]u8,
	length, cursor: int,
	active, select_all: bool,
}

Text_Input_Result :: struct {changed, committed, canceled: bool}

text_field_text :: proc(field: ^Text_Field) -> string {return string(field.buffer[:field.length])}

text_field_set :: proc(field: ^Text_Field, value: string) -> bool {
	if field==nil || len(value)>len(field.buffer) || !utf8.valid_string(value) {return false}
	for character in value {if !unicode.is_graphic(character) {return false}}
	copy(field.buffer[:],value)
	field.length=len(value); field.cursor=field.length; field.select_all=false
	return true
}

// Shared by typing and paste. Rejected replacements leave the selection intact.
text_field_insert :: proc(field: ^Text_Field, value: string) -> bool {
	if field==nil || len(value)==0 || !utf8.valid_string(value) {return false}
	for character in value {if !unicode.is_graphic(character) {return false}}
	start,end:=field.cursor,field.cursor
	if field.select_all {start,end=0,field.length}
	length:=field.length-(end-start)+len(value)
	if length>len(field.buffer) {return false}
	buffer:[1024]u8
	copy(buffer[:start],field.buffer[:start])
	copy(buffer[start:start+len(value)],value)
	copy(buffer[start+len(value):length],field.buffer[end:field.length])
	field.buffer=buffer; field.length=length; field.cursor=start+len(value); field.select_all=false
	return true
}

text_field_delete :: proc(field: ^Text_Field, backward: bool) -> bool {
	if field==nil || field.length==0 {return false}
	if field.select_all {field.length=0; field.cursor=0; field.select_all=false; return true}
	start,end:=field.cursor,field.cursor
	if backward {
		if start==0 {return false}
		_,size:=utf8.decode_last_rune(string(field.buffer[:start])); start-=max(1,size)
	} else {
		if end==field.length {return false}
		_,size:=utf8.decode_rune(string(field.buffer[end:field.length])); end+=max(1,size)
	}
	copy(field.buffer[start:],field.buffer[end:field.length])
	field.length-=end-start; field.cursor=start
	return true
}

// Click or focused accept begins editing. Enter commits, Escape cancels, and
// moving focus commits. The caller decides whether to restore text on cancel.
// Supports UTF-8, arrows, Home/End, Backspace/Delete and Ctrl+A/C/V/X.
text_input :: proc(ui: ^Context, id: string, field: ^Text_Field, enabled: bool = true) -> Text_Input_Result {
	assert(ui.building)
	if field==nil {return {}}
	key:=widget(ui,id,enabled)
	result:Text_Input_Result
	was_active:=field.active
	if field.active && (key!=ui.focus_id || !enabled) {field.active=false; result.committed=true}
	if enabled && !ui.inputs.blocked {
		if !field.active && (ui.clicked_id==key || (ui.inputs.activate && ui.focus_id==key)) {
			field.active=true; field.cursor=field.length; field.select_all=true
		}
		if field.active && was_active && ui.inputs.cancel {field.active=false; result.canceled=true}
		else if field.active && was_active && ui.inputs.activate {field.active=false; result.committed=true}
		else if field.active && was_active && rl.IsWindowReady() {
			control:=rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
			if rl.IsKeyPressed(.ESCAPE) {field.active=false; result.canceled=true}
			else if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {field.active=false; result.committed=true}
			else {
				if control && rl.IsKeyPressed(.A) {field.select_all=true}
				if control && (rl.IsKeyPressed(.C) || rl.IsKeyPressed(.X)) && field.select_all {
					rl.SetClipboardText(fmt.ctprintf("%s",text_field_text(field)))
					if rl.IsKeyPressed(.X) {result.changed=text_field_delete(field,true)}
				}
				if control && rl.IsKeyPressed(.V) {if pasted:=rl.GetClipboardText(); pasted!=nil {result.changed=text_field_insert(field,string(pasted)) || result.changed}}
				if rl.IsKeyPressed(.HOME) {field.cursor=0; field.select_all=false}
				if rl.IsKeyPressed(.END) {field.cursor=field.length; field.select_all=false}
				if rl.IsKeyPressed(.LEFT) || rl.IsKeyPressedRepeat(.LEFT) {
					if field.select_all {field.cursor=0} else if field.cursor>0 {_,size:=utf8.decode_last_rune(string(field.buffer[:field.cursor])); field.cursor-=max(1,size)}
					field.select_all=false
				}
				if rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressedRepeat(.RIGHT) {
					if field.select_all {field.cursor=field.length} else if field.cursor<field.length {_,size:=utf8.decode_rune(string(field.buffer[field.cursor:field.length])); field.cursor+=max(1,size)}
					field.select_all=false
				}
				if rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressedRepeat(.BACKSPACE) {result.changed=text_field_delete(field,true) || result.changed}
				if rl.IsKeyPressed(.DELETE) || rl.IsKeyPressedRepeat(.DELETE) {result.changed=text_field_delete(field,false) || result.changed}
				for character:=rl.GetCharPressed(); character!=0; character=rl.GetCharPressed() {
					if control {continue}
					encoded,count:=utf8.encode_rune(rune(character))
					result.changed=text_field_insert(field,string(encoded[:count])) || result.changed
				}
			}
		}
	}
	background:=ui.style.surface
	if !enabled {background=ui.style.disabled} else if field.active {background=ui.style.pressed} else if key==ui.hovered_id {background=ui.style.hover}
	panel(ui,id,{layout={sizing={width=grow({}),height=fixed(ui.style.height)},padding=padding(8),childAlignment={y=.Center}},
		backgroundColor=background,cornerRadius=corners(ui.style.radius),clip={horizontal=true,vertical=true},
		border={color=ui.style.accent,width=clay.BorderOutside(2 if enabled && key==ui.focus_id && !ui.inputs.blocked else 0)}})
	// Keep the caret end visible for paths longer than the field's width. Text is
	// clipped by the panel; the complete value remains in caller-owned storage.
	start:=0
	if field.active {
		previous:=clay.GetElementData({id=key})
		if previous.found {
			capacity:=max(8,int((previous.boundingBox.width-24)/(f32(ui.style.font_size)*0.6)))
			start=max(0,field.cursor-capacity)
			for start>0 && !utf8.rune_start(field.buffer[start]) {start-=1}
		}
	}
	display:=text_field_text(field)[start:]
	if field.active && !field.select_all {display=fmt.tprintf("%s|%s",string(field.buffer[start:field.cursor]),string(field.buffer[field.cursor:field.length]))}
	label(ui,display,ui.style.accent if field.active && field.select_all else ui.style.text)
	end_panel(ui)
	return result
}
