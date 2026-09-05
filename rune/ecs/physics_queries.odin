package ecs

import "core:math"
import "core:slice"

Physics_Query_Filter :: struct {
	layers:          u64,
	ignore:          Entity,
	include_sensors: bool,
}

Default_Physics_Query_Filter :: Physics_Query_Filter {
	layers          = ~u64(0),
	include_sensors = true,
}

physics_query_vector_valid :: proc(v: [$N]f32) -> bool {
	for x in v {
		if math.is_nan(x) || math.is_inf(x) {return false}
	}
	return true
}

physics_query_entities :: proc(entities: []Entity) -> []Entity {
	slice.sort(entities)
	count := 0
	for entity in entities {
		if count == 0 || entities[count - 1] != entity {
			entities[count] = entity
			count += 1
		}
	}
	return entities[:count]
}
