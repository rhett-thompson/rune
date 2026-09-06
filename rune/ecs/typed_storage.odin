package ecs

import "core:math"
import "core:mem"
import "core:reflect"

// Each custom value owns its deserialized storage. Replacements are prepared
// before releasing the previous value, including when the input borrows its
// strings or collections. The shared World arena remains for resources.
new_typed_value_arena :: proc() -> ^mem.Dynamic_Arena {
	arena, err := mem.new(mem.Dynamic_Arena)
	if err != nil {return nil}
	mem.dynamic_arena_init(arena, block_size = 1024, out_band_size = 1024)
	return arena
}

destroy_typed_value_arena :: proc(arena: ^mem.Dynamic_Arena) {
	mem.dynamic_arena_destroy(arena)
	mem.free(arena)
}

release_typed_value :: proc(world: ^World, value: any) {
	if arena, found := world.typed_value_arenas[value.data]; found {
		delete_key(&world.typed_value_arenas, value.data)
		if arena != nil {destroy_typed_value_arena(arena)} else {mem.free(value.data)}
	}
}

// Keep the direct assignment path conservative: ordinary numeric/bool fields,
// fixed arrays, and nested structs. JSON tags and other types retain the JSON
// conversion path. This decision is cached at registration, not on every set.
typed_value_can_copy :: proc(info: ^reflect.Type_Info) -> bool {
	info := reflect.type_info_base(info)
	#partial switch value in info.variant {
	case reflect.Type_Info_Integer, reflect.Type_Info_Boolean:
		return true
	case reflect.Type_Info_Float:
		return info.id == f16 || info.id == f32 || info.id == f64
	case reflect.Type_Info_Array:
		return typed_value_can_copy(value.elem)
	case reflect.Type_Info_Struct:
		if value.soa_kind != .None {return false}
		for index in 0 ..< int(value.field_count) {
			if reflect.struct_tag_get(reflect.Struct_Tag(value.tags[index]), "json") != "" ||
			   !typed_value_can_copy(value.types[index]) {return false}
		}
		return true
	}
	return false
}

// Reject non-finite numbers before an in-place write, as JSON conversion does.
typed_copy_value_valid :: proc(data: rawptr, info: ^reflect.Type_Info) -> bool {
	info := reflect.type_info_base(info)
	#partial switch value in info.variant {
	case reflect.Type_Info_Float:
		number: f64
		switch info.size {
		case 2: number = f64((^f16)(data)^)
		case 4: number = f64((^f32)(data)^)
		case 8: number = (^f64)(data)^
		case: return false
		}
		return !math.is_nan(number) && !math.is_inf(number)
	case reflect.Type_Info_Array:
		for index in 0 ..< value.count {
			if !typed_copy_value_valid(mem.ptr_offset((^u8)(data), index * value.elem.size), value.elem) {return false}
		}
	case reflect.Type_Info_Struct:
		for index in 0 ..< int(value.field_count) {
			if !typed_copy_value_valid(mem.ptr_offset((^u8)(data), int(value.offsets[index])), value.types[index]) {return false}
		}
	}
	return true
}
