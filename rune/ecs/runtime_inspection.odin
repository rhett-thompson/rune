package ecs

import "core:encoding/json"
import "core:mem"
import "core:slice"
import "core:strconv"
import "core:strings"

// Snapshot current values in scene JSON format. All nested storage belongs to
// allocator; the default expires when the current frame's scratch arena resets.
runtime_component_json :: proc(
	world: ^World,
	entity: Entity,
	name: string,
	allocator := context.temp_allocator,
) -> (json.Value, bool) {
	if !has_component_data(world, entity, name) {return {}, false}
	descriptor := world.component_descriptors[name]
	if descriptor.serialize != nil {
		return descriptor.serialize(world, entity, name, allocator)
	}
	if descriptor.create_typed != nil {
		return custom_component_json(world, entity, name, allocator)
	}
	data, found := get_component(world, entity, name)
	return json.clone_value(data, allocator), found
}

custom_component_json :: proc(world: ^World, entity: Entity, name: string, allocator: mem.Allocator) -> (json.Value, bool) {
	components, found := world.typed_component_data[name]
	if !found {return {}, false}
	component, exists := components[entity]
	if !exists {return {}, false}
	return runtime_json(component, allocator)
}

typed_component_serializer :: proc($T: typeid) -> Component_Serialize_Proc {
	return proc(world: ^World, entity: Entity, name: string, allocator: mem.Allocator) -> (json.Value, bool) {
		component, found := get(world, entity, T)
		if !found {return {}, false}
		when T == Skybox {return skybox_json(component, allocator)}
		when T == PostProcessing {return post_processing_json(component, allocator)}
		when T == TilemapRenderer {
			return tilemap_renderer_json(component, allocator)
		} else when T == TilemapCollider {
			tiles := make([dynamic]i32, context.temp_allocator)
			for id, solid in component.solid_tiles {
				if solid {append(&tiles, id)}
			}
			slice.sort(tiles[:])
			return runtime_json(struct {solid_tiles: []i32}{tiles[:]}, allocator)
		} else {
			value, ok := runtime_json(component)
			if !ok {return {}, false}
			object, is_object := value.(json.Object)
			if !is_object {return json.clone_value(value, allocator), true}

			// Normalize in scratch, then clone the complete public value so keys
			// and replacement fields can also be freed with the output allocator.
			when T == SpriteRenderer || T == MeshRenderer || T == SphereRenderer ||
			     T == ModelRenderer || T == AmbientLight || T == DirectionalLight ||
			     T == PointLight || T == SpotLight || T == TextRenderer || T == ShapeRenderer2D {
				color_keys := []string{"color", "tint"}
				for key in color_keys {
					if color, exists := object[key].(json.Object); exists {
						channels := make(json.Array, 4, context.temp_allocator)
						channels[0], channels[1], channels[2], channels[3] = color["r"], color["g"], color["b"], color["a"]
						object[key] = channels
					}
				}
			}
			when T == CapsuleCollider2D {
				object["axis"] = json.String("vertical" if component.axis == .vertical else "horizontal")
			}
			when T == ShapeRenderer2D {
				object["shape"] = json.String("rectangle" if component.shape == .rectangle else "circle")
			}
			when T == RigidBody2D || T == RigidBody3D {
				object["type"] = object["body_type"]
				delete_key(&object, "body_type")
			} else when T == CameraFollow2D {
				object["target"] = json.String(component.target.id)
				delete_key(&object, "has_bounds")
				if !component.has_bounds {delete_key(&object, "bounds")}
			} else when T == NavGrid2D {
				object["algorithm"] = json.String("a_star" if component.algorithm == .A_Star else "theta_star")
			}
			return json.clone_value(object, allocator), true
		}
	}
}

tilemap_renderer_json :: proc(tilemap: TilemapRenderer, allocator: mem.Allocator) -> (json.Value, bool) {
	object := make(json.Object, context.temp_allocator)
	if tilemap.tileset != "" {
		object["tileset"] = json.String(tilemap.tileset)
	}
	if tilemap.texture != "" {
		object["texture"] = json.String(tilemap.texture)
	}
	if tilemap.tile_size[0] > 0 && tilemap.tile_size[1] > 0 {
		object["tile_size"], _ = runtime_json(tilemap.tile_size)
	}
	object["draw_order"] = json.Integer(tilemap.draw_order)
	grid := make(json.Array, int(tilemap.grid_size[1]), context.temp_allocator)
	for y in 0..<len(grid) {
		row := make(json.Array, int(tilemap.grid_size[0]), context.temp_allocator)
		for x in 0..<len(row) {
			index, found := tilemap.tile_indices[{i32(x), i32(y)}]
			row[x] = json.Integer(index if found else -1)
		}
		grid[y] = row
	}
	object["grid"] = grid
	return json.clone_value(object, allocator), true
}

audio_players_json :: proc(world: ^World, entity: Entity, name: string, allocator: mem.Allocator) -> (json.Value, bool) {
	object := make(json.Object, context.temp_allocator)
	for key, player in world.audio_players {
		if key.entity != entity {continue}
		data, valid := runtime_json(player)
		if !valid {return {}, false}
		fields := data.(json.Object)
		fields["bus"] = json.String(audio_bus_name(player.bus))
		object[key.name] = data
	}
	return json.clone_value(object, allocator), true
}

runtime_json :: proc(value: any, allocator := context.temp_allocator) -> (json.Value, bool) {
	bytes, err := json.marshal(value, allocator = context.temp_allocator)
	if err != nil {return {}, false}
	result: json.Value
	if json.unmarshal(bytes, &result, allocator = allocator) != nil {return {}, false}
	return result, true
}

// Only existing paths can change. Array coordinates use numeric segments,
// e.g. Transform.position.0; an entire vector can also be replaced.
patch_json_field :: proc(value: json.Value, path: string, replacement: json.Value) -> bool {
	head, tail := path, ""
	if dot := strings.index_byte(path, '.'); dot >= 0 {head, tail = path[:dot], path[dot+1:]}
	if head == "" || (tail == "" && strings.has_suffix(path, ".")) {return false}
	#partial switch node in value {
	case json.Object:
		object := node
		child, found := object[head]
		if !found {return false}
		if tail == "" {
			object[head] = replacement
			return true
		}
		return patch_json_field(child, tail, replacement)
	case json.Array:
		index, valid := strconv.parse_int(head, 10)
		if !valid || index < 0 || index >= len(node) {return false}
		if tail == "" {
			node[index] = replacement
			return true
		}
		return patch_json_field(node[index], tail, replacement)
	}
	return false
}

set_runtime_field :: proc(world: ^World, registry: ^Component_Registry, entity: Entity, name, field: string, replacement: json.Value) -> bool {
	data, found := runtime_component_json(world, entity, name)
	if !found || !patch_json_field(data, field, replacement) {return false}
	// These are solver state, not authored CharacterController settings.
	if name == "CharacterController" && (field == "grounded" || field == "vertical_velocity") {return false}
	return add_component(world, registry, entity, name, data)
}
