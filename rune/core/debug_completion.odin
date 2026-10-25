package core

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "rune:console"
import "rune:ecs"

// Providers borrow the current binding only during completion. A scene reload
// or a different engine loop can replace the World before the next Tab press.
@(private)
debug_argument_completion :: proc(dev: ^console.Console, request: console.Completion_Request, candidates: ^[dynamic]string) {
	engine := cast(^Engine)dev.user_data
	if engine == nil {return}
	world := engine.debug.world
	switch request.command {
	case "step":
		if request.argument_index == 0 {append(candidates, "--fast")}
	case "window":
		if request.argument_index == 0 {append(candidates, "windowed", "borderless", "fullscreen")}
	case "input":
		if request.argument_index == 0 {
			for action in engine.input.mappings.actions {append(candidates, action)}
		} else if request.argument_index == 1 {
			append(candidates, "press", "release", "clear")
		}
	case "entities":
		if request.argument_index == 0 {
			for name in engine.registry.components {append(candidates, name)}
		}
	case "navmesh":
		if request.argument_index == 0 {append(candidates, "on", "off")}
		if world != nil && request.argument_index == 1 && len(request.arguments) >= 1 && request.arguments[0] == "on" {
			if entity, picked := debug_picked_entity(engine); picked && ecs.has_component_data(world, entity, "NavMesh3D") {append(candidates, "@picked")}
			for entity in world.entities {
				if !ecs.has_component_data(world, entity, "NavMesh3D") {continue}
				if label := completion_entity_label(engine, world, entity); label != "" {append(candidates, label)}
			}
		}
	case "inspect", "enable", "disable", "set":
		if world == nil {return}
		if request.argument_index == 0 {
			if _, picked := debug_picked_entity(engine); picked {append(candidates, "@picked")}
			for entity in world.entities {
				if label := completion_entity_label(engine, world, entity); label != "" {append(candidates, label)}
			}
			return
		}
		if request.argument_index != 1 || len(request.arguments) < 1 || (request.command != "inspect" && request.command != "set") {return}
		entity, found := debug_entity(engine, world, request.arguments[0])
		if !found {return}
		for name, components in world.component_data {
			if _, attached := components[entity]; !attached {continue}
			if request.command == "inspect" {append(candidates, name); continue}
			if strings.contains(name, ".") {continue}
			base := fmt.tprintf("%s.", name)
			// Avoid snapshotting components that the typed prefix cannot match.
			if !strings.has_prefix(base, request.prefix) && !strings.has_prefix(request.prefix, base) {continue}
			value, valid := ecs.runtime_component_json(world, entity, name)
			if !valid {continue}
			field_prefix := ""
			if strings.has_prefix(request.prefix, base) {field_prefix = request.prefix[len(base):]}
			completion_field_paths(candidates, base, value, field_prefix, name == "CharacterController")
		}
	}
}

@(private)
completion_entity_label :: proc(engine: ^Engine, world: ^ecs.World, entity: ecs.Entity) -> string {
	label := entity_label(world, entity)
	if label == "@picked" || !utf8.valid_string(label) {label = fmt.tprintf("@%d", u64(entity))}
	for character in label {
		if !unicode.is_graphic(character) {label = fmt.tprintf("@%d", u64(entity)); break}
	}
	// A scene ID can resemble a fallback handle; offer only labels that resolve
	// to the intended entity under the same rules as the command handler.
	resolved, found := debug_entity(engine, world, label)
	if !found || resolved != entity {return ""}
	return label
}

@(private)
completion_field_paths :: proc(candidates: ^[dynamic]string, base: string, value: json.Value, prefix: string, controller: bool) {
	// Descend only through the path already typed, so large arrays do not
	// recursively expand and each Tab suggests the next existing segment.
	if dot := strings.index_byte(prefix, '.'); dot >= 0 {
		segment, rest := prefix[:dot], prefix[dot+1:]
		if segment == "" {return}
		child: json.Value
		#partial switch node in value {
		case json.Object:
			found: bool
			child, found = node[segment]
			if !found {return}
		case json.Array:
			index, valid := strconv.parse_int(segment, 10)
			if !valid || index < 0 || index >= len(node) {return}
			child = node[index]
		case: return
		}
		completion_field_paths(candidates, fmt.tprintf("%s%s.", base, segment), child, rest, false)
		return
	}
	#partial switch node in value {
	case json.Object:
		for field in node {
			if field == "" || strings.contains(field, ".") {continue}
			if controller && (field == "grounded" || field == "vertical_velocity") {continue}
			append(candidates, fmt.tprintf("%s%s", base, field))
		}
	case json.Array:
		for index in 0..<len(node) {append(candidates, fmt.tprintf("%s%d", base, index))}
	}
}
