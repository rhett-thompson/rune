package save

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "rune:ecs"

// Returns a frame-scratch path. Slot names cannot address other directories.
slot_path :: proc(manager: ^Manager, slot: string, backup := false) -> (string, bool) {
	if !manager.initialized || !valid_slot(slot) {return "", fail(manager, "Invalid save slot; use 1-80 letters, digits, underscores or hyphens")}
	suffix := ".save.json.bak" if backup else ".save.json"
	return filepath.join({manager.options.directory, fmt.tprintf("%s%s", slot, suffix)}, context.temp_allocator) or_else "", true
}

// Sync the complete temporary file before replacing the destination. Rename
// replaces existing files on both supported platforms (Windows and Linux).
write_synced :: proc(path: string, bytes: []u8) -> bool {
	f, err := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
	if err != nil {return false}
	n, write_error := os.write(f, bytes)
	ok := write_error == nil && n == len(bytes)
	if ok {ok = os.sync(f) == nil}
	close_error := os.close(f)
	return ok && close_error == nil
}

write_slot :: proc(manager: ^Manager, slot: string) -> bool {
	clear_error(manager)
	path, ok := slot_path(manager, slot)
	if !ok {return false}
	if manager.checkpoint.document.active_scene == "" {return fail(manager, "No checkpoint to write")}
	bytes, err := json.marshal(manager.checkpoint.document, allocator = context.temp_allocator)
	if err != nil {return fail(manager, "Could not encode save slot '%s'", slot)}
	if os.make_directory_all(manager.options.directory) != nil {return fail(manager, "Could not create save directory '%s'", manager.options.directory)}
	temporary := fmt.tprintf("%s.tmp", path)
	defer os.remove(temporary)
	if !write_synced(temporary, bytes) {return fail(manager, "Could not write temporary save '%s'", temporary)}
	if os.exists(path) {
		old, read_error := os.read_entire_file(path, context.temp_allocator)
		if read_error != nil {return fail(manager, "Could not back up save '%s'", slot)}
		backup := fmt.tprintf("%s.bak", path)
		backup_temp := fmt.tprintf("%s.tmp", backup)
		defer os.remove(backup_temp)
		if !write_synced(backup_temp, old) || os.rename(backup_temp, backup) != nil {return fail(manager, "Could not replace backup for '%s'", slot)}
	}
	if os.rename(temporary, path) != nil {return fail(manager, "Could not replace save slot '%s'; previous slot retained", slot)}
	return true
}

read_slot :: proc(manager: ^Manager, slot: string, backup := false) -> (Checkpoint, bool) {
	clear_error(manager)
	path, valid := slot_path(manager, slot, backup)
	if !valid {return {}, false}
	result := new_checkpoint()
	success := false
	defer if !success {destroy_checkpoint(&result)}
	a := allocator(&result)
	bytes, err := os.read_entire_file(path, a)
	if err != nil {return {}, fail(manager, "Could not read save slot '%s'", slot)}
	value: json.Value
	if json.unmarshal(bytes, &value, allocator = a) != nil || !ecs.json_shape_matches_type(value, typeid_of(Document)) ||
	   json.unmarshal(bytes, &result.document, allocator = a) != nil {return {}, fail(manager, "Malformed save slot '%s'", slot)}
	doc := &result.document
	if doc.format_version != Format_Version || doc.game_id != manager.options.game_id || doc.game_version < 1 || doc.game_version > manager.options.game_version {
		return {}, fail(manager, "Incompatible save format, game ID, or game version in '%s'", slot)
	}
	if doc.game_version < manager.options.game_version {
		if manager.options.migrate == nil || !manager.options.migrate(doc, doc.game_version, manager.options.game_version, a) {
			return {}, fail(manager, "Save '%s' needs a successful game-version migration", slot)
		}
		doc.game_version = manager.options.game_version
	}
	if doc.format_version != Format_Version || doc.game_id != manager.options.game_id || doc.active_scene == "" {return {}, fail(manager, "Invalid checkpoint header")}
	if _, found := doc.scenes[doc.active_scene]; !found {return {}, fail(manager, "Active scene missing from checkpoint")}
	for key in doc.scenes {
		canonical, ok := scene_key(manager, key, a)
		if !ok || canonical != key {return {}, fail(manager, "Invalid saved scene path '%s'", key)}
	}
	success = true
	return result, true
}
