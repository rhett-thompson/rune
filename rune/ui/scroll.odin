package ui

import "core:math"
import clay "../../third_party/clay/clay-odin"

@(private)
Scroll_Gutter :: f32(16)
@(private)
Scroll_Inset :: f32(2)
// Vendored clay.h, Clay_UpdateScrollContainers, multiplies wheel input by 10.
@(private)
Clay_Wheel_Scale :: f32(10)

@(private)
Scroll_Panel_Frame :: struct {
	id: u32,
	depth: int,
	horizontal,vertical: bool,
}

@(private)
Scroll_Focus_Ancestor :: struct {
	widget: u32,
	panel: int,
}

// Floating roots without inherited clipping have their own scroll ancestry.
// In particular, dropdown options must not scroll the menu behind their popup.
@(private)
scroll_focus_open :: proc(ui:^Context,declaration:Element) {
	if declaration.floating.attachTo!=.None && declaration.floating.clipTo==.None {
		append(&ui.scroll_floating_depths,ui.depth)
	}
}

@(private)
scroll_focus_close :: proc(ui:^Context) {
	for len(ui.scroll_floating_depths)>0 && ui.scroll_floating_depths[len(ui.scroll_floating_depths)-1]>ui.depth {
		pop(&ui.scroll_floating_depths)
	}
}

@(private)
scroll_focus_widget :: proc(ui:^Context,key:u32) {
	floor:=ui.scroll_floating_depths[len(ui.scroll_floating_depths)-1] if len(ui.scroll_floating_depths)>0 else 0
	for index:=len(ui.scroll_stack)-1;index>=0;index-=1 {
		panel:=ui.scroll_stack[index]
		if ui.scroll_panels[panel].depth<floor {break}
		append(&ui.scroll_focus_ancestors,Scroll_Focus_Ancestor{key,panel})
	}
}

// Called only after explicit navigation and the completed layout, with this
// context selected. Inner-to-outer updates keep a nested control visible through
// every ancestor clip without disturbing independent lists or idle wheel input.
@(private)
scroll_reveal_focus :: proc(ui:^Context) {
	widget:=clay.GetElementData({id=ui.focus_id})
	if !widget.found {return}
	target:=widget.boundingBox
	for ancestor in ui.scroll_focus_ancestors {
		if ancestor.widget!=ui.focus_id {continue}
		frame:=ui.scroll_panels[ancestor.panel]
		viewport:=clay.GetElementData({id=frame.id})
		data:=clay.GetScrollContainerData({id=frame.id})
		if !viewport.found || !data.found || data.scrollPosition==nil {continue}
		for axis in 0..<2 {
			if !(frame.vertical if axis==1 else frame.horizontal) {continue}
			start:=target.y if axis==1 else target.x
			size:=target.height if axis==1 else target.width
			origin:=viewport.boundingBox.y if axis==1 else viewport.boundingBox.x
			length:=viewport.boundingBox.height if axis==1 else viewport.boundingBox.width
			content:=data.contentDimensions.height if axis==1 else data.contentDimensions.width
			if !(length>0) || !(content>length) {continue}
			delta:f32
			if start<origin || size>length {delta=origin-start}
			else if start+size>origin+length {delta=origin+length-start-size}
			before:=data.scrollPosition^[axis]
			data.scrollPosition^[axis]=clamp(before+delta,-(content-length),0)
			if axis==1 {target.y+=data.scrollPosition^[axis]-before}
			else {target.x+=data.scrollPosition^[axis]-before}
		}
	}
}

@(private)
Scroll_Bar_Geometry :: struct {
	track,thumb: clay.BoundingBox,
	range,travel,thumb_ratio,leading_ratio: f32,
	visible: bool,
}

@(private)
scroll_track_id :: proc(viewport:u32,axis:int) -> clay.ElementId {
	return clay.ID("__rune_vertical_scroll_track" if axis==1 else "__rune_horizontal_scroll_track",viewport)
}

@(private)
scroll_thumb_id :: proc(viewport:u32,axis:int) -> clay.ElementId {
	return clay.ID("__rune_vertical_scroll_thumb" if axis==1 else "__rune_horizontal_scroll_thumb",viewport)
}

@(private)
scroll_step :: proc(step:f32) -> f32 {
	return step if step>0 && !math.is_nan(step) && !math.is_inf(step) else 60
}

@(private)
scroll_wheel_for_clay :: proc(wheel:[2]f32,step:f32) -> [2]f32 {
	result:=wheel
	for &value in result[:] {
		value=value*scroll_step(step)/Clay_Wheel_Scale if !math.is_nan(value) && !math.is_inf(value) else 0
	}
	return result
}

@(private)
scroll_bar_geometry :: proc(track:clay.BoundingBox,viewport,content:[2]f32,offset:f32,axis:int) -> Scroll_Bar_Geometry {
	result:=Scroll_Bar_Geometry{track=track}
	length:=track.height if axis==1 else track.width
	if !(length>0) || !(viewport[axis]>0) || !(content[axis]>viewport[axis]) ||
		math.is_inf(length) || math.is_inf(content[axis]) || math.is_nan(offset) || math.is_inf(offset) {return result}
	result.range=content[axis]-viewport[axis]
	result.thumb_ratio=clamp(max(viewport[axis]/content[axis],min(24/length,1)),0,1)
	result.travel=length*(1-result.thumb_ratio)
	result.leading_ratio=clamp(-offset/result.range,0,1)*(1-result.thumb_ratio)
	result.thumb=track
	if axis==1 {result.thumb.y+=length*result.leading_ratio; result.thumb.height=length*result.thumb_ratio}
	else {result.thumb.x+=length*result.leading_ratio; result.thumb.width=length*result.thumb_ratio}
	result.visible=true
	return result
}

@(private)
scroll_contains :: proc(rect:clay.BoundingBox,point:[2]f32) -> bool {
	return point[0]>=rect.x && point[0]<=rect.x+rect.width && point[1]>=rect.y && point[1]<=rect.y+rect.height
}

// Only IDs persist across frames; Clay may move its internal scroll data when
// pruning panels. Refetch data with the owning context selected at every use.
@(private)
scroll_geometry :: proc(frame:Scroll_Panel_Frame,axis:int) -> (Scroll_Bar_Geometry,clay.ScrollContainerData) {
	data:=clay.GetScrollContainerData({id=frame.id})
	track:=clay.GetElementData(scroll_track_id(frame.id,axis))
	if !data.found || data.scrollPosition==nil || !track.found ||
		!(frame.vertical if axis==1 else frame.horizontal) {return {},data}
	return scroll_bar_geometry(track.boundingBox,{data.scrollContainerDimensions.width,data.scrollContainerDimensions.height},
		{data.contentDimensions.width,data.contentDimensions.height},data.scrollPosition^[axis],axis),data
}

// Clay selects one deepest clip before checking its overflow. Single-line
// fields and fitting nested panels must instead let each wheel axis reach the
// deepest hovered viewport that can actually scroll on that axis.
@(private)
scroll_viewports_wheel :: proc(ui:^Context) -> bool {
	wheel:=scroll_wheel_for_clay(ui.inputs.scroll,ui.style.scroll_step)*Clay_Wheel_Scale
	if wheel[0]==0 && wheel[1]==0 {return false}
	hovered:=false
	for axis in 0..<2 {
		for index:=len(ui.previous_scroll_panels)-1;index>=0;index-=1 {
			frame:=ui.previous_scroll_panels[index]
			if !clay.PointerOver({id=frame.id}) {continue}
			hovered=true
			if wheel[axis]==0 || !(frame.vertical if axis==1 else frame.horizontal) {continue}
			data:=clay.GetScrollContainerData({id=frame.id})
			if !data.found || data.scrollPosition==nil {continue}
			content:=data.contentDimensions.height if axis==1 else data.contentDimensions.width
			viewport:=data.scrollContainerDimensions.height if axis==1 else data.scrollContainerDimensions.width
			if !(content>viewport) {continue}
			data.scrollPosition^[axis]=clamp(data.scrollPosition^[axis]+wheel[axis],-(content-viewport),0)
			break
		}
	}
	return hovered
}

// Own the full press/drag/release before widget routing. Keyboard navigation
// stays independent; a scrollbar never steals widget focus.
@(private)
scroll_bars_input :: proc(ui:^Context) -> bool {
	ui.scroll_hover_id=0
	if ui.inputs.blocked {ui.scroll_drag_id=0; return false}
	hover_frame:Scroll_Panel_Frame
	hover_axis:=0
	hovered:=false
	for index:=len(ui.previous_scroll_panels)-1; index>=0 && !hovered; index-=1 {
		frame:=ui.previous_scroll_panels[index]
		for axis in 0..<2 {
			geometry,_:=scroll_geometry(frame,axis)
			if geometry.visible && clay.PointerOver(scroll_track_id(frame.id,axis)) {
				hover_frame,hover_axis,hovered=frame,axis,true
				ui.scroll_hover_id=scroll_track_id(frame.id,axis).id
				break
			}
		}
	}
	if ui.scroll_drag_id!=0 {
		if !ui.inputs.pointer_down {ui.scroll_drag_id=0; return true}
		found:=false
		for frame in ui.previous_scroll_panels {
			if frame.id!=ui.scroll_drag_id {continue}
			geometry,data:=scroll_geometry(frame,ui.scroll_drag_axis)
			if geometry.visible {
				found=true
				scroll_drag(data.scrollPosition,geometry,ui.inputs.pointer,ui.scroll_drag_axis,ui.scroll_drag_offset)
			}
			break
		}
		if !found {ui.scroll_drag_id=0}
		return true
	}
	if !hovered {return scroll_viewports_wheel(ui)}
	geometry,data:=scroll_geometry(hover_frame,hover_axis)
	if ui.inputs.pointer_down && !ui.last_down {
		ui.scroll_drag_id,ui.scroll_drag_axis=hover_frame.id,hover_axis
		origin:=geometry.thumb.y if hover_axis==1 else geometry.thumb.x
		length:=geometry.thumb.height if hover_axis==1 else geometry.thumb.width
		ui.scroll_drag_offset=ui.inputs.pointer[hover_axis]-origin if scroll_contains(geometry.thumb,ui.inputs.pointer) else length*0.5
		scroll_drag(data.scrollPosition,geometry,ui.inputs.pointer,hover_axis,ui.scroll_drag_offset)
	} else {
		wheel:=scroll_wheel_for_clay(ui.inputs.scroll,ui.style.scroll_step)*Clay_Wheel_Scale
		if hover_axis==0 && wheel[0]==0 {wheel[0]=wheel[1]; wheel[1]=0}
		if hover_frame.horizontal {data.scrollPosition^[0]=clamp(data.scrollPosition^[0]+wheel[0],-max(data.contentDimensions.width-data.scrollContainerDimensions.width,0),0)}
		if hover_frame.vertical {data.scrollPosition^[1]=clamp(data.scrollPosition^[1]+wheel[1],-max(data.contentDimensions.height-data.scrollContainerDimensions.height,0),0)}
	}
	return true
}

@(private)
scroll_drag :: proc(position:^[2]f32,geometry:Scroll_Bar_Geometry,pointer:[2]f32,axis:int,grab:f32) {
	if geometry.travel<=0 || math.is_nan(pointer[axis]) || math.is_inf(pointer[axis]) {return}
	origin:=geometry.track.y if axis==1 else geometry.track.x
	position^[axis]=-clamp((pointer[axis]-origin-grab)/geometry.travel,0,1)*geometry.range
}

@(private)
scroll_open :: proc(declaration:Element) {
	clay._OpenElement(); clay.ConfigureOpenElement(declaration)
}

// Preserve explicit bounds: a scroll container still has an inferred minimum
// from padding/gaps, so replacing a constrained axis with unbounded grow can
// make it extend past a fixed or capped parent.
@(private)
scroll_viewport_sizing :: proc(original:clay.SizingAxis,gutter:f32) -> clay.SizingAxis {
	if original.type==.Percent {return grow({})}
	if original.type==.Fixed {return fixed(max(0,original.constraints.sizeMinMax.max-gutter))}
	limits:=original.constraints.sizeMinMax
	limits.min=max(0,limits.min-gutter)
	if limits.max>0 {limits.max=max(0,limits.max-gutter)}
	return fit(limits) if original.type==.Fit else grow(limits)
}

@(private)
open_scroll_panel :: proc(ui:^Context,id:string,declaration:Element,horizontal,vertical:bool) {
	key:=clay.ID(id).id
	outer:=declaration
	outer.id=clay.ID("__rune_scroll_outer",key)
	outer.layout={sizing=declaration.layout.sizing,layoutDirection=.TopToBottom}
	outer.clip={}
	scroll_open(outer); ui.depth+=1
	scroll_focus_open(ui,outer)
	row:=Element{id=clay.ID("__rune_scroll_row",key),layout={sizing={width=grow({}),height=grow({})}}}
	if declaration.layout.sizing.width.type==.Fixed {row.layout.sizing.width=declaration.layout.sizing.width}
	if declaration.layout.sizing.height.type==.Fixed {
		row.layout.sizing.height=fixed(max(0,declaration.layout.sizing.height.constraints.sizeMinMax.max-(Scroll_Gutter if horizontal else 0)))
	}
	scroll_open(row); ui.depth+=1
	viewport:=Element{layout=declaration.layout,clip={horizontal=horizontal,vertical=vertical}}
	viewport.layout.sizing.width=scroll_viewport_sizing(viewport.layout.sizing.width,Scroll_Gutter if vertical else 0)
	viewport.layout.sizing.height=scroll_viewport_sizing(viewport.layout.sizing.height,Scroll_Gutter if horizontal else 0)
	data:=clay.GetScrollContainerData({id=key})
	if data.found && data.scrollPosition!=nil {viewport.clip.childOffset=data.scrollPosition^}
	panel(ui,id,viewport)
	append(&ui.scroll_stack,len(ui.scroll_panels))
	append(&ui.scroll_panels,Scroll_Panel_Frame{key,ui.depth,horizontal,vertical})
}

@(private)
close_scroll_panel :: proc(ui:^Context) {
	index:=pop(&ui.scroll_stack)
	frame:=ui.scroll_panels[index]
	clay._CloseElement(); ui.depth-=1
	if frame.vertical {scroll_bar_layout(ui,frame,1)}
	clay._CloseElement(); ui.depth-=1
	if frame.horizontal {
		scroll_open({id=clay.ID("__rune_scroll_bottom",frame.id),layout={sizing={width=grow({}),height=fixed(Scroll_Gutter)}}})
		scroll_bar_layout(ui,frame,0)
		if frame.vertical {scroll_open({layout={sizing={width=fixed(Scroll_Gutter),height=grow({})}}}); clay._CloseElement()}
		clay._CloseElement()
	}
	clay._CloseElement(); ui.depth-=1
	scroll_focus_close(ui)
}

// Ordinary layout children keep both rendering and pointer hits inside every
// ancestor clip. Percentage spacers/thumbs also remain clamped during resize.
// Gutters introduce no extra Clay scroll containers.
@(private)
scroll_bar_layout :: proc(ui:^Context,frame:Scroll_Panel_Frame,axis:int) {
	data:=clay.GetScrollContainerData({id=frame.id})
	viewport:=[2]f32{data.scrollContainerDimensions.width,data.scrollContainerDimensions.height}
	track:=clay.BoundingBox{width=viewport[0]-2*Scroll_Inset,height=viewport[1]-2*Scroll_Inset}
	geometry:Scroll_Bar_Geometry
	if data.found && data.scrollPosition!=nil {geometry=scroll_bar_geometry(track,viewport,
		{data.contentDimensions.width,data.contentDimensions.height},data.scrollPosition^[axis],axis)}
	slot:=Element{layout={sizing={width=grow({}),height=grow({})},padding=padding(u16(Scroll_Inset))}}
	if axis==1 {slot.layout.sizing.width=fixed(Scroll_Gutter)}
	scroll_open(slot)
	track_config:=Element{id=scroll_track_id(frame.id,axis),layout={sizing={width=grow({}),height=grow({})}},cornerRadius=corners(6)}
	if axis==1 {track_config.layout.layoutDirection=.TopToBottom}
	if geometry.visible {track_config.backgroundColor=ui.style.surface}
	scroll_open(track_config)
	if geometry.visible {
		spacer:=Element{layout={sizing={width=grow({}),height=grow({})}}}
		thumb:=Element{id=scroll_thumb_id(frame.id,axis),layout={sizing={width=grow({}),height=grow({})}},
			backgroundColor=ui.style.disabled if ui.inputs.blocked else ui.style.accent if ui.scroll_drag_id==frame.id && ui.scroll_drag_axis==axis else ui.style.hover if ui.scroll_hover_id==track_config.id.id else ui.style.muted,
			cornerRadius=corners(6)}
		if axis==1 {spacer.layout.sizing.height=percent(geometry.leading_ratio); thumb.layout.sizing.height=percent(geometry.thumb_ratio)}
		else {spacer.layout.sizing.width=percent(geometry.leading_ratio); thumb.layout.sizing.width=percent(geometry.thumb_ratio)}
		scroll_open(spacer); clay._CloseElement()
		scroll_open(thumb); clay._CloseElement()
	}
	clay._CloseElement(); clay._CloseElement()
}
