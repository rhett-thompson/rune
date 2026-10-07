package main

import "core:os"
import "rune:save"

validate_save_directories :: proc(manager: ^save.Manager) {
	original_directory := manager.options.directory
	defer {manager.options.directory = original_directory}
	directory :: "build/save-validation/directory-regression"
	// Remove only this validator's known files; no recursive cleanup is needed.
	for path in ([]string{
		"build/save-validation/directory-regression/first.save.json",
		"build/save-validation/directory-regression/first.save.json.bak",
		"build/save-validation/directory-regression/second.save.json",
	}) {os.remove(path)}
	os.remove(directory)
	assert(!os.exists(directory))
	manager.options.directory = directory
	check(save.write_slot(manager, "first"), manager)
	assert(os.is_directory(directory), "the first save creates its directory")
	check(save.write_slot(manager, "first"), manager)
	check(save.write_slot(manager, "second"), manager)
	backup, read := save.read_slot(manager, "first", backup = true)
	check(read, manager)
	save.destroy_checkpoint(&backup)
	// An existing file must never be accepted as a save directory.
	blocked :: "build/save-validation/directory-blocker"
	assert(os.write_entire_file(blocked, "keep") == nil)
	defer os.remove(blocked)
	manager.options.directory = blocked
	assert(!save.write_slot(manager, "first"))
	assert(save.last_error(manager) != "")
	bytes, err := os.read_entire_file(blocked, context.temp_allocator)
	assert(err == nil && string(bytes) == "keep")
}
