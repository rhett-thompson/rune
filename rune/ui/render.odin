package ui

import "core:math"
import "core:mem"
import "core:strings"
import clay "../../third_party/clay/clay-odin"
import rl "vendor:raylib"

Custom_Draw_Proc :: #type proc(command: clay.RenderCommand)

// Draw completed commands in screen space, outside BeginMode2D/3D. This never
// evaluates controls or changes gameplay. Text/image references survive until
// the next begin. Fonts and textures remain owned by the caller/asset manager.
draw :: proc(ui: ^Context, custom: Custom_Draw_Proc = nil) -> bool {
	if !ui.ready || ui.building {return false}
	clips := make([dynamic]rl.Rectangle, mem.dynamic_arena_allocator(&ui.scratch))
	defer if len(clips) > 0 {rl.EndScissorMode()}
	for command in ui.commands.internalArray[:ui.commands.length] {
		box := command.boundingBox
		rect := rl.Rectangle{box.x, box.y, box.width, box.height}
		switch command.commandType {
		case .None:
		case .Rectangle:
			data := command.renderData.rectangle
			draw_box(rect, data.cornerRadius, color_to_raylib(data.backgroundColor))
		case .Text:
			data := command.renderData.text
			text := string(data.stringContents.chars[:data.stringContents.length])
			text_c, _ := strings.clone_to_cstring(text, mem.dynamic_arena_allocator(&ui.scratch))
			rl.DrawTextEx(ui.font, text_c, {box.x, box.y}, f32(data.fontSize),
				f32(data.letterSpacing), color_to_raylib(data.textColor))
		case .Image:
			data := command.renderData.image
			if data.imageData == nil {continue}
			texture := (^rl.Texture2D)(data.imageData)^
			if texture.id == 0 || texture.width <= 0 || texture.height <= 0 {continue}
			rl.DrawTexturePro(texture, {0, 0, f32(texture.width), f32(texture.height)}, rect,
				{}, 0, color_to_raylib(data.backgroundColor))
		case .Border:
			draw_border(rect, command.renderData.border)
		case .ScissorStart:
			if len(clips) > 0 {rect = intersect(rect, clips[len(clips)-1])}
			append(&clips, rect)
			apply_clip(rect)
		case .ScissorEnd:
			if len(clips) > 0 {pop(&clips)}
			if len(clips) > 0 {apply_clip(clips[len(clips)-1])} else {rl.EndScissorMode()}
		case .Custom:
			if custom != nil {custom(command)}
			else {record_error(ui, "Clay custom element requires a custom draw callback"); return false}
		}
	}
	return true
}

@(private)
color_to_raylib :: proc(color: Color) -> rl.Color {
	return {u8(clamp(color[0], 0, 255)), u8(clamp(color[1], 0, 255)),
		u8(clamp(color[2], 0, 255)), u8(clamp(color[3], 0, 255))}
}

// Clay supports independent corner radii. A triangle fan preserves them without
// relying on raylib's single-radius rounded rectangle helper.
@(private)
draw_box :: proc(rect: rl.Rectangle, corners: clay.CornerRadius, color: rl.Color) {
	if rect.width <= 0 || rect.height <= 0 || color.a == 0 {return}
	limit := min(rect.width, rect.height) * 0.5
	radii := [4]f32{clamp(corners.topLeft, 0, limit), clamp(corners.bottomLeft, 0, limit),
		clamp(corners.bottomRight, 0, limit), clamp(corners.topRight, 0, limit)}
	centers := [4]rl.Vector2{
		{rect.x+radii[0], rect.y+radii[0]},
		{rect.x+radii[1], rect.y+rect.height-radii[1]},
		{rect.x+rect.width-radii[2], rect.y+rect.height-radii[2]},
		{rect.x+rect.width-radii[3], rect.y+radii[3]},
	}
	vertices: [38]rl.Vector2
	vertices[0] = {rect.x+rect.width/2, rect.y+rect.height/2}
	count := 1
	for center, corner in centers {
		for segment in 0 ..= 8 {
			angle := (-90-f32(corner)*90-f32(segment)*90/8) * (math.PI/180)
			vertices[count] = center + rl.Vector2{math.cos(angle), math.sin(angle)} * radii[corner]
			count += 1
		}
	}
	vertices[count] = vertices[1]
	rl.DrawTriangleFan(raw_data(vertices[:]), i32(count+1), color)
}

@(private)
draw_border :: proc(rect: rl.Rectangle, border: clay.BorderRenderData) {
	color := color_to_raylib(border.color)
	w := border.width
	r := border.cornerRadius
	limit := min(rect.width, rect.height)/2
	r.topLeft, r.topRight = clamp(r.topLeft, 0, limit), clamp(r.topRight, 0, limit)
	r.bottomLeft, r.bottomRight = clamp(r.bottomLeft, 0, limit), clamp(r.bottomRight, 0, limit)
	if w.left > 0 {rl.DrawRectangleRec({rect.x,rect.y+r.topLeft,f32(w.left),max(0,rect.height-r.topLeft-r.bottomLeft)},color)}
	if w.right > 0 {rl.DrawRectangleRec({rect.x+rect.width-f32(w.right),rect.y+r.topRight,f32(w.right),max(0,rect.height-r.topRight-r.bottomRight)},color)}
	if w.top > 0 {rl.DrawRectangleRec({rect.x+r.topLeft,rect.y,max(0,rect.width-r.topLeft-r.topRight),f32(w.top)},color)}
	if w.bottom > 0 {rl.DrawRectangleRec({rect.x+r.bottomLeft,rect.y+rect.height-f32(w.bottom),max(0,rect.width-r.bottomLeft-r.bottomRight),f32(w.bottom)},color)}
	if r.topLeft > 0 && w.top > 0 {rl.DrawRing({rect.x+r.topLeft,rect.y+r.topLeft},max(0,r.topLeft-f32(w.top)),r.topLeft,180,270,8,color)}
	if r.topRight > 0 && w.top > 0 {rl.DrawRing({rect.x+rect.width-r.topRight,rect.y+r.topRight},max(0,r.topRight-f32(w.top)),r.topRight,270,360,8,color)}
	if r.bottomLeft > 0 && w.bottom > 0 {rl.DrawRing({rect.x+r.bottomLeft,rect.y+rect.height-r.bottomLeft},max(0,r.bottomLeft-f32(w.bottom)),r.bottomLeft,90,180,8,color)}
	if r.bottomRight > 0 && w.bottom > 0 {rl.DrawRing({rect.x+rect.width-r.bottomRight,rect.y+rect.height-r.bottomRight},max(0,r.bottomRight-f32(w.bottom)),r.bottomRight,0,90,8,color)}
}

@(private)
intersect :: proc(a,b: rl.Rectangle) -> rl.Rectangle {
	x,y := max(a.x,b.x),max(a.y,b.y)
	return {x,y,max(0,min(a.x+a.width,b.x+b.width)-x),max(0,min(a.y+a.height,b.y+b.height)-y)}
}

@(private)
apply_clip :: proc(rect: rl.Rectangle) {
	x,y := math.floor(rect.x),math.floor(rect.y)
	rl.BeginScissorMode(i32(x),i32(y),i32(max(0,math.ceil(rect.x+rect.width)-x)),i32(max(0,math.ceil(rect.y+rect.height)-y)))
}
