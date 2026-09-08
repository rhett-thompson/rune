package render

import "core:math"
import "rune:ecs"
import rl "vendor:raylib"

// Shapes share the sprite draw list and inherited 2D transform. Circles become
// ellipses under nonuniform scale; outlines use world-space line width.
draw_shape_2d :: proc(shape: ecs.ShapeRenderer2D, command: Render_2D_Command) {
	if command.scale[0] == 0 || command.scale[1] == 0 {return}
	points: [64]rl.Vector2
	count := 4 if shape.shape == .rectangle else len(points)
	size := shape.size if shape.shape == .rectangle else [2]f32{shape.radius * 2, shape.radius * 2}
	angle := command.rotation * (math.PI / 180)
	cosine, sine := math.cos(angle), math.sin(angle)
	for i in 0..<count {
		local: [2]f32
		if shape.shape == .rectangle {
			corners := [4][2]f32{{0, 0}, {1, 0}, {1, 1}, {0, 1}}
			local = corners[i] * size
		} else {
			theta := f32(i) * (2 * math.PI / f32(count))
			local = {shape.radius * (1 + math.cos(theta)), shape.radius * (1 + math.sin(theta))}
		}
		local = (local - shape.origin * size) * command.scale
		points[i] = {command.position[0] + local[0] * cosine - local[1] * sine,
			command.position[1] + local[0] * sine + local[1] * cosine}
	}
	color := to_raylib_color(shape.color)
	if shape.filled {
		for i in 1..<count-1 {
			draw_shape_triangle(points[0], points[i], points[i+1], color)
		}
	} else {
		// Shared miter vertices close every join without overlapping translucent
		// line caps or leaving gaps on curved outlines.
		offsets: [64]rl.Vector2
		for i in 0..<count {
			previous := points[i] - points[(i+count-1)%count]
			next := points[(i+1)%count] - points[i]
			previous /= math.sqrt(previous.x*previous.x + previous.y*previous.y)
			next /= math.sqrt(next.x*next.x + next.y*next.y)
			normal_a := rl.Vector2{-previous.y, previous.x}
			normal_b := rl.Vector2{-next.y, next.x}
			denominator := max(f32(0.001), 1 + normal_a.x*normal_b.x + normal_a.y*normal_b.y)
			offsets[i] = (normal_a + normal_b) * (shape.line_width * 0.5 / denominator)
		}
		for i in 0..<count {
			j := (i+1)%count
			a, b := points[i] + offsets[i], points[j] + offsets[j]
			c, d := points[j] - offsets[j], points[i] - offsets[i]
			draw_shape_triangle(a, b, c, color)
			draw_shape_triangle(a, c, d, color)
		}
	}
}

// Raylib triangles require counterclockwise winding, including reflected shapes.
draw_shape_triangle :: proc(a, b, c: rl.Vector2, color: rl.Color) {
	b, c := b, c
	cross := (b.x-a.x)*(c.y-a.y) - (b.y-a.y)*(c.x-a.x)
	if cross > 0 {b, c = c, b}
	rl.DrawTriangle(a, b, c, color)
}
