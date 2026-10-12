package ui

import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import clay "../../third_party/clay/clay-odin"
import rl "vendor:raylib"

// Caller-owned multiline UTF-8 storage. Values are never silently truncated.
// Cursor and anchor are byte offsets on rune boundaries; unequal values select
// that range. Text is borrowed until the next edit, as with Text_Field.
Text_Area :: struct {
	buffer: [8192]u8,
	length, cursor, anchor: int,
	active: bool,
	preferred_column: int,
	vertical_move: bool,
	reveal: bool,
}

Text_Area_Move :: enum {Left, Right, Up, Down, Home, End, Document_Start, Document_End}

text_area_text :: proc(area:^Text_Area) -> string {return string(area.buffer[:area.length])}

@(private)
text_area_normalize :: proc(value:string, buffer:[]u8) -> (int,bool) {
	if !utf8.valid_string(value) {return 0,false}
	for character in value {if !unicode.is_graphic(character) && character!='\n' && character!='\r' && character!='\t' {return 0,false}}
	length:=0
	for byte,i in transmute([]u8)value {
		if byte=='\n' && i>0 && value[i-1]=='\r' {continue}
		if length>=len(buffer) {return 0,false}
		buffer[length]='\n' if byte=='\r' else byte; length+=1
	}
	return length,true
}

text_area_set :: proc(area:^Text_Area,value:string) -> bool {
	if area==nil {return false}
	buffer:[8192]u8
	length,valid:=text_area_normalize(value,buffer[:])
	if !valid {return false}
	area.buffer=buffer; area.length=length; area.cursor=length; area.anchor=length
	area.vertical_move=false; area.reveal=true
	return true
}

text_area_insert :: proc(area:^Text_Area,value:string) -> bool {
	if area==nil || len(value)==0 {return false}
	normalized:[8192]u8
	count,valid:=text_area_normalize(value,normalized[:])
	if !valid {return false}
	start,end:=min(area.cursor,area.anchor),max(area.cursor,area.anchor)
	length:=area.length-(end-start)+count
	if length>len(area.buffer) {return false}
	buffer:[8192]u8
	copy(buffer[:start],area.buffer[:start]); copy(buffer[start:start+count],normalized[:count])
	copy(buffer[start+count:length],area.buffer[end:area.length])
	area.buffer=buffer; area.length=length; area.cursor=start+count; area.anchor=area.cursor
	area.vertical_move=false; area.reveal=true
	return true
}

text_area_delete :: proc(area:^Text_Area,backward:bool) -> bool {
	if area==nil || area.length==0 {return false}
	start,end:=min(area.cursor,area.anchor),max(area.cursor,area.anchor)
	if start==end {
		if backward {if start==0 {return false}; _,size:=utf8.decode_last_rune(string(area.buffer[:start])); start-=max(1,size)}
		else {if end==area.length {return false}; _,size:=utf8.decode_rune(string(area.buffer[end:area.length])); end+=max(1,size)}
	}
	copy(area.buffer[start:],area.buffer[end:area.length]); area.length-=end-start
	area.cursor=start; area.anchor=start; area.vertical_move=false; area.reveal=true
	return true
}

@(private)
text_area_line_start :: proc(area:^Text_Area,offset:int) -> int {
	start:=clamp(offset,0,area.length)
	for start>0 && area.buffer[start-1]!='\n' {start-=1}
	return start
}

@(private)
text_area_line_end :: proc(area:^Text_Area,offset:int) -> int {
	end:=clamp(offset,0,area.length)
	for end<area.length && area.buffer[end]!='\n' {end+=1}
	return end
}

// Shared by native key handling and headless tests. Vertical movement preserves
// a Unicode column across short lines; horizontal/home/end starts a new column.
text_area_move :: proc(area:^Text_Area,direction:Text_Area_Move,select:bool=false) {
	if area==nil {return}
	cursor:=area.cursor
	start,end:=text_area_line_start(area,cursor),text_area_line_end(area,cursor)
	switch direction {
	case .Left:
		if !select && area.cursor!=area.anchor {cursor=min(area.cursor,area.anchor)}
		else if cursor>0 {_,size:=utf8.decode_last_rune(string(area.buffer[:cursor])); cursor-=max(1,size)}
	case .Right:
		if !select && area.cursor!=area.anchor {cursor=max(area.cursor,area.anchor)}
		else if cursor<area.length {_,size:=utf8.decode_rune(string(area.buffer[cursor:area.length])); cursor+=max(1,size)}
	case .Home: cursor=start
	case .End: cursor=end
	case .Document_Start: cursor=0
	case .Document_End: cursor=area.length
	case .Up,.Down:
		if !area.vertical_move {
			area.preferred_column=0
			for _ in string(area.buffer[start:cursor]) {area.preferred_column+=1}
		}
		if direction==.Up {if start==0 {return}; end=start-1; start=text_area_line_start(area,end)}
		else {if end==area.length {return}; start=end+1; end=text_area_line_end(area,start)}
		cursor=start
		for _ in 0..<area.preferred_column {if cursor>=end {break}; _,size:=utf8.decode_rune(string(area.buffer[cursor:end])); cursor+=max(1,size)}
	}
	area.vertical_move=direction==.Up || direction==.Down
	area.cursor=cursor; if !select {area.anchor=cursor}; area.reveal=true
}

@(private)
text_area_expanded :: proc(ui:^Context,value:string,initial_column:int=0) -> string {
	buffer:=make([]u8,len(value)*4,mem.dynamic_arena_allocator(&ui.scratch))
	length,column:=0,initial_column
	for character in value {
		if character=='\t' {for _ in 0..<4-column%4 {buffer[length]=' '; length+=1; column+=1}}
		else {encoded,count:=utf8.encode_rune(character); copy(buffer[length:length+count],encoded[:count]); length+=count; column+=1}
	}
	return string(buffer[:length])
}

@(private)
text_area_width :: proc(ui:^Context,value:string) -> f32 {
	if ui.measure!=nil {return ui.measure(value,f32(ui.style.font_size),0)[0]}
	value_c,_:=strings.clone_to_cstring(value,mem.dynamic_arena_allocator(&ui.scratch))
	return rl.MeasureTextEx(ui.font,value_c,f32(ui.style.font_size),0).x
}

@(private)
text_area_label :: proc(ui:^Context,value:string,color:Color) {
	if value=="" {return}
	clay.TextDynamic(copy_text(ui,value),clay.TextConfig({textColor=color,fontSize=ui.style.font_size,wrapMode=.None}))
}

// Click/focused accept activates. Enter inserts a paragraph; Ctrl+Enter or
// transferring focus commits, Escape cancels. The caller owns the saved value
// and decides whether to restore it on cancel. Only active, unblocked areas read
// the native character queue. Explicit lines scroll in both directions.
text_area :: proc(ui:^Context,id:string,area:^Text_Area,enabled:bool=true,height:f32=160) -> Text_Input_Result {
	assert(ui.building)
	if area==nil {return {}}
	key:=widget(ui,id,enabled)
	result:Text_Input_Result
	was_active:=area.active
	// Up/Down may also be mapped to menu navigation. While editing, those
	// native arrows belong to the caret; Tab/gamepad focus transfer still commits.
	if area.active && !ui.inputs.blocked && key!=ui.focus_id && (ui.inputs.next || ui.inputs.previous) && rl.IsWindowReady() {
		if rl.IsKeyPressed(.UP) || rl.IsKeyPressedRepeat(.UP) || rl.IsKeyPressed(.DOWN) || rl.IsKeyPressedRepeat(.DOWN) {ui.focus_id=key}
	}
	if area.active && (key!=ui.focus_id || !enabled) {area.active=false; result.committed=true}
	if enabled && !ui.inputs.blocked {
		if !area.active && (ui.clicked_id==key || (ui.inputs.activate && ui.focus_id==key)) {area.active=true; area.reveal=true}
		if area.active && was_active && ui.inputs.cancel {area.active=false; result.canceled=true}
		else if area.active && was_active && ui.inputs.activate && (!rl.IsWindowReady() || (!rl.IsKeyPressed(.ENTER) && !rl.IsKeyPressed(.KP_ENTER))) {area.active=false; result.committed=true}
		else if area.active && was_active && rl.IsWindowReady() {
			control:=rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
			shift:=rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
			if rl.IsKeyPressed(.ESCAPE) {area.active=false; result.canceled=true}
			else if control && (rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER)) {area.active=false; result.committed=true}
			else {
				if control && rl.IsKeyPressed(.A) {area.anchor=0; area.cursor=area.length; area.reveal=true}
				if control && (rl.IsKeyPressed(.C) || rl.IsKeyPressed(.X)) && area.cursor!=area.anchor {
					start,end:=min(area.cursor,area.anchor),max(area.cursor,area.anchor)
					rl.SetClipboardText(fmt.ctprintf("%s",string(area.buffer[start:end])))
					if rl.IsKeyPressed(.X) {result.changed=text_area_delete(area,true)}
				}
				if control && rl.IsKeyPressed(.V) {if pasted:=rl.GetClipboardText(); pasted!=nil {result.changed=text_area_insert(area,string(pasted)) || result.changed}}
				if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {result.changed=text_area_insert(area,"\n") || result.changed}
				if rl.IsKeyPressed(.HOME) {text_area_move(area,.Document_Start if control else .Home,shift)}
				if rl.IsKeyPressed(.END) {text_area_move(area,.Document_End if control else .End,shift)}
				for direction in ([4]Text_Area_Move{.Left,.Right,.Up,.Down}) {
					key:rl.KeyboardKey
					#partial switch direction {case .Left:key=.LEFT;case .Right:key=.RIGHT;case .Up:key=.UP;case .Down:key=.DOWN}
					if rl.IsKeyPressed(key) || rl.IsKeyPressedRepeat(key) {text_area_move(area,direction,shift)}
				}
				if rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressedRepeat(.BACKSPACE) {result.changed=text_area_delete(area,true) || result.changed}
				if rl.IsKeyPressed(.DELETE) || rl.IsKeyPressedRepeat(.DELETE) {result.changed=text_area_delete(area,false) || result.changed}
				for character:=rl.GetCharPressed(); character!=0; character=rl.GetCharPressed() {
					if control {continue}; encoded,count:=utf8.encode_rune(rune(character))
					result.changed=text_area_insert(area,string(encoded[:count])) || result.changed
				}
			}
		}
	}
	line_height:=f32(ui.style.font_size)+6
	actual_height:=height if height>=line_height+32 && !math.is_inf(height) else max(f32(160),line_height+32)
	starts,ends:[8193]int
	count,start:=0,0
	for byte,i in area.buffer[:area.length] {if byte=='\n' {starts[count],ends[count]=start,i; count+=1; start=i+1}}
	starts[count],ends[count]=start,area.length; count+=1
	max_width:=f32(1); caret_line:=0
	for i in 0..<count {
		line:=text_area_expanded(ui,string(area.buffer[starts[i]:ends[i]]))
		max_width=max(max_width,text_area_width(ui,line)+4)
		if area.cursor>=starts[i] && area.cursor<=ends[i] {caret_line=i}
	}
	scroll:=clay.GetScrollContainerData({id=key})
	viewport:=clay.GetElementData({id=key})
	if !area.active && area.reveal && scroll.found && scroll.scrollPosition!=nil {scroll.scrollPosition^={}; area.reveal=false}
	if area.active && ui.clicked_id==key && viewport.found {
		offset:=[2]f32{}; if scroll.found && scroll.scrollPosition!=nil {offset=scroll.scrollPosition^}
		line:=clamp(int((ui.inputs.pointer[1]-viewport.boundingBox.y-8-offset[1])/line_height),0,count-1)
		x:=max(0,ui.inputs.pointer[0]-viewport.boundingBox.x-8-offset[0])
		cursor:=starts[line]
		for cursor<ends[line] {
			_,size:=utf8.decode_rune(string(area.buffer[cursor:ends[line]])); next:=cursor+max(1,size)
			left:=text_area_width(ui,text_area_expanded(ui,string(area.buffer[starts[line]:cursor])))
			right:=text_area_width(ui,text_area_expanded(ui,string(area.buffer[starts[line]:next])))
			if x<(left+right)*0.5 {break}; cursor=next
		}
		area.cursor=cursor; area.anchor=cursor; area.vertical_move=false; area.reveal=true; caret_line=line
	}
	if area.active && area.reveal && scroll.found && scroll.scrollPosition!=nil {
		x:=text_area_width(ui,text_area_expanded(ui,string(area.buffer[starts[caret_line]:area.cursor])))+8
		y:=f32(caret_line)*line_height+8
		width,viewport_height:=scroll.scrollContainerDimensions.width,scroll.scrollContainerDimensions.height
		if x+scroll.scrollPosition^[0]<8 {scroll.scrollPosition^[0]=8-x}
		if x+scroll.scrollPosition^[0]>width-12 {scroll.scrollPosition^[0]=width-12-x}
		if y+scroll.scrollPosition^[1]<8 {scroll.scrollPosition^[1]=8-y}
		if y+line_height+scroll.scrollPosition^[1]>viewport_height-8 {scroll.scrollPosition^[1]=viewport_height-8-line_height-y}
		scroll.scrollPosition^[0]=clamp(scroll.scrollPosition^[0],-max(0,max_width+16-width),0)
		scroll.scrollPosition^[1]=clamp(scroll.scrollPosition^[1],-max(0,f32(count)*line_height+16-viewport_height),0)
		area.reveal=false
	}
	first:=0
	if scroll.found && scroll.scrollPosition!=nil {first=clamp(int((-scroll.scrollPosition^[1]-8)/line_height)-1,0,count-1)}
	last:=min(count,first+int(actual_height/line_height)+4)
	background:=ui.style.surface
	if !enabled {background=ui.style.disabled} else if area.active {background=ui.style.pressed} else if key==ui.hovered_id {background=ui.style.hover}
	scroll_panel(ui,id,{layout={sizing={width=grow({}),height=fixed(actual_height)},padding=padding(8),layoutDirection=.TopToBottom},
		backgroundColor=background,cornerRadius=corners(ui.style.radius),
		border={color=ui.style.accent,width=clay.BorderOutside(2 if enabled && key==ui.focus_id && !ui.inputs.blocked else 0)}},true,true)
	// Spacers retain the complete document's dimensions while only a bounded
	// number of line widgets are created, even for thousands of empty lines.
	if first>0 {panel(ui,fmt.tprintf("%s_before",id),{layout={sizing={width=fixed(max_width),height=fixed(f32(first)*line_height)}}}); end_panel(ui)}
	selection_start,selection_end:=min(area.cursor,area.anchor),max(area.cursor,area.anchor)
	for i in first..<last {
		panel(ui,fmt.tprintf("%s_line_%d",id,i),{layout={sizing={width=fixed(max_width),height=fixed(line_height)},childAlignment={y=.Center}}})
		line_start,line_end:=starts[i],ends[i]
		selected_start,selected_end:=clamp(selection_start,line_start,line_end),clamp(selection_end,line_start,line_end)
		points:=[5]int{line_start,selected_start,selected_end,line_end,line_end}
		if area.active && area.cursor>=line_start && area.cursor<=line_end {
			points[4]=area.cursor
			for j in 1..<5 {for k:=j;k>0 && points[k]<points[k-1];k-=1 {points[k],points[k-1]=points[k-1],points[k]}}
		}
		caret_drawn:=false
		for point,j in points {
			if area.active && !caret_drawn && point==area.cursor && i==caret_line {
				panel(ui,fmt.tprintf("%s_caret",id),{layout={sizing={width=fixed(2),height=fixed(f32(ui.style.font_size)+2)}},backgroundColor=ui.style.accent}); end_panel(ui); caret_drawn=true
			}
			if j==4 || points[j+1]<=point {continue}
			selected:=area.active && point>=selection_start && points[j+1]<=selection_end && selection_start!=selection_end
			column:=0
			for character in string(area.buffer[line_start:point]) {column+=4-column%4 if character=='\t' else 1}
			text_area_label(ui,text_area_expanded(ui,string(area.buffer[point:points[j+1]]),column),ui.style.accent if selected else ui.style.text)
		}
		end_panel(ui)
	}
	if last<count {panel(ui,fmt.tprintf("%s_after",id),{layout={sizing={width=fixed(max_width),height=fixed(f32(count-last)*line_height)}}}); end_panel(ui)}
	end_panel(ui)
	return result
}
