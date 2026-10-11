package core

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
projects_can_omit_input_but_reject_invalid_mapping_paths :: proc(t: ^testing.T) {
	directory, err := os.make_directory_temp("", "rune-no-input-*", context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer delete(directory)
	defer os.remove(directory)
	path := fmt.tprintf("%s/project.json", directory)
	defer os.remove(path)
	documents := []string{
		`{"name":"No input","window":{}}`,
		`{"name":"Empty input","window":{},"input":""}`,
		`{"name":"Wrong input","window":{},"input":2}`,
		`{"name":"Missing input","window":{},"input":"missing.input.json"}`,
	}
	for document, index in documents {
		testing.expect(t, os.write_entire_file(path, document) == nil)
		project, ok := load_project(path)
		testing.expect(t, ok == (index < 2))
		if ok {
			testing.expect(t, project.input == "")
			destroy_project(&project)
		}
	}
}
