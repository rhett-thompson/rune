package ui

import "core:fmt"
import "core:math"
import clay "../../third_party/clay/clay-odin"

// Caller-owned interaction state. Options and the selected index stay with the
// caller; no strings or heap allocations are retained by this control.
Dropdown :: struct {
	open: bool,
	highlighted: int,
	pointer: [2]f32,
	pointer_down: bool,
	reveal: bool,
}

// A zero-based selection. Invalid indices display a prompt until an option is
// chosen. Declare before other controls in the same menu so the open popup can
// consume their keyboard input. The floating list does not affect menu layout.
dropdown :: proc(ctx:^Context,id:string,state:^Dropdown,selected:^int,options:[]string,
	enabled:bool=true,height:f32=240) -> bool {
	assert(ctx.building)
	usable:=enabled && state!=nil && selected!=nil && len(options)>0
	text:="No options" if len(options)==0 else "Select..."
	if selected!=nil && selected^>=0 && selected^<len(options) {text=options[selected^]}
	if !usable {
		if state!=nil {state.open=false;state.reveal=false;state.pointer=ctx.inputs.pointer;state.pointer_down=ctx.inputs.pointer_down}
		button(ctx,id,text,false)
		return false
	}
	controls:=ctx.inputs
	key:=clay.ID(id).id
	was_open:=state.open
	if was_open && !controls.blocked {
		if controls.cancel || (controls.pointer_down && !state.pointer_down &&
			!clay.PointerOver({id=key}) && !clay.PointerOver(clay.ID(fmt.tprintf("%s_popup",id)))) {
			state.open=false;state.reveal=false
			ctx.active_id,ctx.clicked_id,ctx.focus_id=0,0,key
			ctx.inputs.activate=false
		}
	}
	if state.open {ctx.inputs.activate=false}
	if button(ctx,id,fmt.tprintf("%s  %s",text,"^" if state.open else "v")) && !controls.blocked {
		state.open=!state.open
		ctx.inputs.activate=false
		if state.open {
			state.highlighted=selected^ if selected^>=0 && selected^<len(options) else 0
			state.reveal=true
		}
	}
	changed:=false
	if state.open {
		state.highlighted=clamp(state.highlighted,0,len(options)-1)
		if was_open && !controls.blocked && controls.next!=controls.previous {
			state.highlighted=(state.highlighted+(1 if controls.next else -1)+len(options))%len(options)
			state.reveal=true
		}
		if !controls.blocked && controls.pointer!=state.pointer {
			for _,i in options {
				if ctx.hovered_id==clay.ID(fmt.tprintf("%s_option_%d",id,i)).id {state.highlighted=i;state.reveal=false;break}
			}
		}
		ctx.focus_id=clay.ID(fmt.tprintf("%s_option_%d",id,state.highlighted)).id
		// Capture pointer hits over the rest of the screen. The list is a separate
		// higher floating root, so its options and scroll gutter remain usable.
		panel(ctx,fmt.tprintf("%s_backdrop",id),{layout={sizing={width=grow({}),height=grow({})}},
			floating={attachTo=.Root,zIndex=1000,pointerCaptureMode=.Capture}})
		end_panel(ctx)
		anchor:=clay.GetElementData({id=key}).boundingBox
		root:=clay.GetElementData(clay.ID("Clay__RootContainer")).boundingBox
		limit:=height if height>0 && !math.is_inf(height) && !math.is_nan(height) else 240
		popup_height:=min(limit,f32(len(options))*(ctx.style.height+4)+8)
		above:=false
		if root.height>0 {
			below:=max(root.height-anchor.y-anchor.height-4,0)
			upper:=max(anchor.y-4,0)
			above=below<popup_height && upper>below
			popup_height=min(popup_height,upper if above else below)
		}
		panel(ctx,fmt.tprintf("%s_popup",id),{
			layout={sizing={width=fixed(max(anchor.width,1)),height=fixed(max(popup_height,1))}},
			floating={attachTo=.ElementWithId,parentId=key,zIndex=1001,pointerCaptureMode=.Capture,
				attachment={element=.LeftBottom if above else .LeftTop,parent=.LeftTop if above else .LeftBottom},offset={0,-4 if above else 4}},
			backgroundColor=ctx.style.surface,cornerRadius=corners(ctx.style.radius),
		})
		list_id:=fmt.tprintf("%s_options",id)
		if state.reveal {
			data:=clay.GetScrollContainerData(clay.ID(list_id))
			if data.found && data.scrollPosition!=nil && data.scrollContainerDimensions.height>0 {
				top:=4+f32(state.highlighted)*(ctx.style.height+4)
				minimum:=min(data.scrollContainerDimensions.height-top-ctx.style.height-4,0)
				maximum:=min(4-top,0)
				data.scrollPosition^[1]=clamp(data.scrollPosition^[1],minimum,maximum)
				state.reveal=false
			}
		}
		scroll_panel(ctx,list_id,{layout={sizing={width=grow({}),height=grow({})},layoutDirection=.TopToBottom,padding=padding(4),childGap=4}},false,true)
		ctx.inputs.activate=controls.activate && was_open && !controls.blocked
		for option,i in options {
			if button(ctx,fmt.tprintf("%s_option_%d",id,i),option) {
				changed=selected^!=i;selected^=i;state.open=false;state.reveal=false
				ctx.focus_id=key;ctx.active_id,ctx.clicked_id=0,0;ctx.inputs.activate=false
			}
		}
		end_panel(ctx);end_panel(ctx)
	}
	state.pointer=controls.pointer
	state.pointer_down=controls.pointer_down
	if was_open || state.open {
		// Inputs are frame-local. Modal ownership ends on the next begin, and the
		// closing click/accept cannot activate an action underneath the popup.
		ctx.inputs.blocked=true
		ctx.inputs.activate,ctx.inputs.cancel,ctx.inputs.next,ctx.inputs.previous=false,false,false,false
	}
	return changed
}
