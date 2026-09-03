package navigation

import "core:math"

Algorithm :: enum {
	A_Star,
	Theta_Star,
}

Point :: struct {
	x, y: i32,
}

Grid :: struct {
	width, height: i32,
	cell_size:     f32,
	origin:        [2]f32,
	blocked:       []bool,
}

init_grid :: proc(width, height: i32, cell_size: f32, origin: [2]f32 = {}) -> (Grid, bool) {
	if width <= 0 || height <= 0 || cell_size <= 0 {return {}, false}
	return Grid {
			width = width,
			height = height,
			cell_size = cell_size,
			origin = origin,
			blocked = make([]bool, int(width * height)),
		},
		true
}

destroy_grid :: proc(grid: ^Grid) {
	delete(grid.blocked)
	grid^ = {}
}

inside :: proc(grid: ^Grid, point: Point) -> bool {
	return point.x >= 0 && point.y >= 0 && point.x < grid.width && point.y < grid.height
}

index_of :: proc(grid: ^Grid, point: Point) -> int {
	return int(point.y * grid.width + point.x)
}

is_blocked :: proc(grid: ^Grid, point: Point) -> bool {
	return !inside(grid, point) || grid.blocked[index_of(grid, point)]
}

set_blocked :: proc(grid: ^Grid, point: Point, blocked := true) -> bool {
	if !inside(grid, point) {return false}
	grid.blocked[index_of(grid, point)] = blocked
	return true
}

world_to_cell :: proc(grid: ^Grid, position: [2]f32) -> Point {
	return {
		i32(math.floor(f64((position[0] - grid.origin[0]) / grid.cell_size))),
		i32(math.floor(f64((position[1] - grid.origin[1]) / grid.cell_size))),
	}
}

cell_center :: proc(grid: ^Grid, point: Point) -> [2]f32 {
	return {
		grid.origin[0] + (f32(point.x) + .5) * grid.cell_size,
		grid.origin[1] + (f32(point.y) + .5) * grid.cell_size,
	}
}

block_world_rect :: proc(grid: ^Grid, minimum, maximum: [2]f32) {
	first := world_to_cell(grid, minimum)
	last := world_to_cell(grid, maximum)
	first.x = max(first.x, 0)
	first.y = max(first.y, 0)
	last.x = min(last.x, grid.width - 1)
	last.y = min(last.y, grid.height - 1)
	for y := first.y; y <= last.y; y += 1 {
		for x := first.x; x <= last.x; x += 1 {
			set_blocked(grid, {x, y})
		}
	}
}

distance :: proc(a, b: Point) -> f32 {
	dx, dy := f32(b.x - a.x), f32(b.y - a.y)
	return f32(math.sqrt(f64(dx * dx + dy * dy)))
}

// line_of_sight uses a supercover traversal. Requiring both orthogonal cells
// at a diagonal boundary keeps an agent from squeezing through blocked corners.
line_of_sight :: proc(grid: ^Grid, start, goal: Point) -> bool {
	x, y := start.x, start.y
	dx, dy := abs(goal.x - start.x), abs(goal.y - start.y)
	sx: i32 = 1 if goal.x >= start.x else -1
	sy: i32 = 1 if goal.y >= start.y else -1
	err := dx - dy
	for {
		if is_blocked(grid, {x, y}) {return false}
		if x == goal.x && y == goal.y {return true}
		e2 := err * 2
		old_x, old_y := x, y
		if e2 > -dy {err -= dy; x += sx}
		if e2 < dx {err += dx; y += sy}
		if x != old_x && y != old_y {
			if is_blocked(grid, {x, old_y}) || is_blocked(grid, {old_x, y}) {return false}
		}
	}
}

find_path :: proc(
	grid: ^Grid,
	start, goal: Point,
	algorithm := Algorithm.A_Star,
) -> (
	[]Point,
	bool,
) {
	if is_blocked(grid, start) || is_blocked(grid, goal) {return nil, false}
	count := int(grid.width * grid.height)
	g_score := make([]f32, count, context.temp_allocator)
	parent := make([]i32, count, context.temp_allocator)
	open := make([]bool, count, context.temp_allocator)
	closed := make([]bool, count, context.temp_allocator)
	for i in 0 ..< count {
		g_score[i] = 3.402823e38
		parent[i] = -1
	}
	start_index, goal_index := index_of(grid, start), index_of(grid, goal)
	g_score[start_index], parent[start_index], open[start_index] = 0, i32(start_index), true

	for {
		current := -1
		best: f32 = 3.402823e38
		for i in 0 ..< count {
			if !open[i] {continue}
			point := Point{i32(i % int(grid.width)), i32(i / int(grid.width))}
			score := g_score[i] + distance(point, goal)
			if score < best {best, current = score, i}
		}
		if current < 0 {return nil, false}
		if current == goal_index {break}
		open[current], closed[current] = false, true
		current_point := Point{i32(current % int(grid.width)), i32(current / int(grid.width))}
		for oy: i32 = -1; oy <= 1; oy += 1 {
			for ox: i32 = -1; ox <= 1; ox += 1 {
				if ox == 0 && oy == 0 {continue}
				next := Point{current_point.x + ox, current_point.y + oy}
				if is_blocked(grid, next) {continue}
				if ox != 0 &&
				   oy != 0 &&
				   (is_blocked(grid, {current_point.x + ox, current_point.y}) ||
						   is_blocked(grid, {current_point.x, current_point.y + oy})) {continue}
				next_index := index_of(grid, next)
				if closed[next_index] {continue}
				source_index := current
				if algorithm == .Theta_Star {
					candidate_parent := int(parent[current])
					if candidate_parent >= 0 {
						candidate := Point {
							i32(candidate_parent % int(grid.width)),
							i32(candidate_parent / int(grid.width)),
						}
						if line_of_sight(grid, candidate, next) {source_index = candidate_parent}
					}
				}
				source := Point {
					i32(source_index % int(grid.width)),
					i32(source_index / int(grid.width)),
				}
				tentative := g_score[source_index] + distance(source, next)
				if tentative < g_score[next_index] {
					g_score[next_index] = tentative
					parent[next_index] = i32(source_index)
					open[next_index] = true
				}
			}
		}
	}

	reversed := make([dynamic]Point)
	cursor := goal_index
	for {
		append(&reversed, Point{i32(cursor % int(grid.width)), i32(cursor / int(grid.width))})
		if cursor == start_index {break}
		cursor = int(parent[cursor])
		if cursor < 0 {delete(reversed); return nil, false}
	}
	path := make([]Point, len(reversed))
	for point, i in reversed {path[len(reversed) - 1 - i] = point}
	delete(reversed)
	return path, true
}
