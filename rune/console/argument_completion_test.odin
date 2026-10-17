package console

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:testing"

Argument_Completion_Probe :: struct {
	t: ^testing.T,
	arguments: []string,
	argument_index: int,
	prefix: string,
	candidates: []string,
	calls: int,
	executed: bool,
	word, rest: string,
}

argument_completion_handler :: proc(dev: ^Console, arguments: string) {
	probe := cast(^Argument_Completion_Probe)dev.user_data
	probe.executed = true
	probe.word, probe.rest = take_argument(arguments)
}

argument_completion_provider :: proc(dev: ^Console, request: Completion_Request, candidates: ^[dynamic]string) {
	probe := cast(^Argument_Completion_Probe)dev.user_data
	probe.calls += 1
	testing.expect(probe.t, request.command == "inspect")
	testing.expect(probe.t, request.argument_index == probe.argument_index)
	testing.expect(probe.t, request.prefix == probe.prefix)
	testing.expect(probe.t, len(request.arguments) == len(probe.arguments))
	for argument, index in request.arguments {
		if index < len(probe.arguments) {
			testing.expect(probe.t, argument == probe.arguments[index])
		}
	}
	append(candidates, ..probe.candidates)
}

@(test)
argument_completion_receives_context_and_cycles_only_the_active_token :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	probe := Argument_Completion_Probe {
		t = t, arguments = {"entity1"}, argument_index = 1, prefix = "Tr",
		candidates = {"Trigger", "Sprite", "Transform"},
	}
	dev := init()
	dev.user_data = &probe
	testing.expect(t, register(&dev, "inspect", "", argument_completion_handler, argument_completion_provider))
	insert_text(&dev, "inspect entity1 Trunfinished field suffix")
	set_input_caret(&dev, len("inspect entity1 Tr"))
	for expected in ([3]string{
		"inspect entity1 Transform field suffix",
		"inspect entity1 Trigger field suffix",
		"inspect entity1 Transform field suffix",
	}) {
		testing.expect(t, complete(&dev))
		testing.expect(t, input_text(&dev) == expected)
	}
	testing.expect(t, complete(&dev, true))
	testing.expect(t, input_text(&dev) == "inspect entity1 Trigger field suffix")
	testing.expect(t, dev.input_caret == len("inspect entity1 Trigger"))
	testing.expect(t, dev.input_anchor == dev.input_caret)
	testing.expect(t, probe.calls == 4 && !probe.executed)
}

@(test)
argument_completion_supports_blank_arguments_and_reverse_cycles :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	probe := Argument_Completion_Probe {
		t = t, arguments = {"entity1"}, argument_index = 1,
		candidates = {"Transform", "Sprite"},
	}
	dev := init()
	dev.user_data = &probe
	register(&dev, "inspect", "", argument_completion_handler, argument_completion_provider)
	insert_text(&dev, "inspect entity1 ")
	testing.expect(t, complete(&dev, true))
	testing.expect(t, input_text(&dev) == "inspect entity1 Transform")
	testing.expect(t, complete(&dev, true))
	testing.expect(t, input_text(&dev) == "inspect entity1 Sprite")
	testing.expect(t, complete(&dev))
	testing.expect(t, input_text(&dev) == "inspect entity1 Transform")
	testing.expect(t, probe.calls == 3 && !probe.executed)
}

@(test)
argument_completion_decodes_prior_tokens_and_unterminated_quoted_prefixes :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	probe := Argument_Completion_Probe {
		t = t, arguments = {"chosen id", "Transform"}, argument_index = 2, prefix = "é",
		candidates = {"éclair entity", "other"},
	}
	dev := init()
	dev.user_data = &probe
	register(&dev, "inspect", "", argument_completion_handler, argument_completion_provider)
	insert_text(&dev, `inspect "chosen id" Transform "é`)
	testing.expect(t, complete(&dev))
	testing.expect(t, input_text(&dev) == `inspect "chosen id" Transform "éclair entity"`)
	testing.expect(t, dev.input_caret == dev.input_len && dev.input_anchor == dev.input_caret)
	testing.expect(t, probe.calls == 1)
}

@(test)
argument_completion_quotes_candidates_so_argument_parsing_roundtrips :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	for candidate in ([5]string{"entity with spaces", `entity"quoted`, `entity\path`, "entity🙂", "entity\u2003wide"}) {
		probe := Argument_Completion_Probe {t = t, prefix = "entity", candidates = {candidate}}
		dev := init()
		dev.user_data = &probe
		register(&dev, "inspect", "", argument_completion_handler, argument_completion_provider)
		insert_text(&dev, "inspect entity trailing")
		set_input_caret(&dev, len("inspect entity"))
		testing.expect(t, complete(&dev))
		testing.expect(t, strings.has_suffix(input_text(&dev), " trailing"))
		testing.expect(t, execute(&dev, input_text(&dev)))
		testing.expect(t, probe.executed && probe.word == candidate && probe.rest == "trailing")
	}
}

@(test)
argument_completion_decodes_json_escapes_before_matching :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	candidate := `box"dir\path name`
	probe := Argument_Completion_Probe {t = t, prefix = `box"dir\pa`, candidates = {candidate}}
	dev := init()
	dev.user_data = &probe
	register(&dev, "inspect", "", argument_completion_handler, argument_completion_provider)
	insert_text(&dev, `inspect "box\"dir\\pa`)
	testing.expect(t, complete(&dev))
	encoded, encode_error := json.marshal(candidate, allocator = context.temp_allocator)
	testing.expect(t, encode_error == nil)
	expected, _ := strings.concatenate({"inspect ", string(encoded)}, context.temp_allocator)
	testing.expect(t, input_text(&dev) == expected)
	testing.expect(t, execute(&dev, input_text(&dev)))
	testing.expect(t, probe.word == candidate && probe.rest == "")
}

@(test)
argument_completion_requeries_dynamic_candidates_and_owns_cycle_bytes :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	borrowed := [3]u8{'c', 'a', 't'}
	probe := Argument_Completion_Probe {t = t, prefix = "c", candidates = {string(borrowed[:]), "cow"}}
	dev := init()
	dev.user_data = &probe
	register(&dev, "inspect", "", argument_completion_handler, argument_completion_provider)
	insert_text(&dev, "inspect c")
	testing.expect(t, complete(&dev))
	testing.expect(t, input_text(&dev) == "inspect cat")
	copy(borrowed[:], "czz")
	probe.candidates = {"cab", "cow", "cow"}
	testing.expect(t, complete(&dev))
	testing.expect(t, input_text(&dev) == "inspect cow")
	probe.candidates = {"camel", "copper"}
	testing.expect(t, complete(&dev))
	testing.expect(t, input_text(&dev) == "inspect camel")
	testing.expect(t, complete(&dev, true))
	testing.expect(t, input_text(&dev) == "inspect copper")
	probe.candidates = {}
	testing.expect(t, !complete(&dev))
	probe.candidates = {"cherry"}
	testing.expect(t, complete(&dev))
	testing.expect(t, input_text(&dev) == "inspect cherry")
	testing.expect(t, probe.calls == 6)
}

argument_input_borrowed_completion :: proc(dev: ^Console, request: Completion_Request, candidates: ^[dynamic]string) {
	append(candidates, string(dev.input[dev.input_len-3:dev.input_len]), "cow")
}

@(test)
argument_completion_owns_suggestions_borrowed_from_the_replaced_input :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	register(&dev, "inspect", "", completion_test_handler, argument_input_borrowed_completion)
	insert_text(&dev, "inspect c cat")
	set_input_caret(&dev, len("inspect c"))
	testing.expect(t, complete(&dev))
	testing.expect(t, input_text(&dev) == "inspect cat cat")
	testing.expect(t, complete(&dev))
	testing.expect(t, input_text(&dev) == "inspect cow cat")
}

@(test)
argument_completion_skips_oversized_and_control_candidates_atomically :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	probe := Argument_Completion_Probe {
		t = t, prefix = "q", candidates = {"q ", "qaa", "qz"},
	}
	dev := init()
	dev.user_data = &probe
	register(&dev, "inspect", "", argument_completion_handler, argument_completion_provider)
	full: [Max_Input_Length]u8
	for &byte in full {byte = 'x'}
	copy(full[:], "inspect q ")
	insert_text(&dev, string(full[:Max_Input_Length - 1]))
	set_input_caret(&dev, len("inspect q"))
	testing.expect(t, complete(&dev))
	testing.expect(t, dev.input_len == Max_Input_Length)
	testing.expect(t, string(dev.input[:len("inspect qz ")]) == "inspect qz ")
	testing.expect(t, strings.has_suffix(input_text(&dev), string(full[len("inspect q "):Max_Input_Length - 1])))
	revision := dev.edit_revision
	testing.expect(t, !complete(&dev, true))
	testing.expect(t, dev.edit_revision == revision && dev.input_len == Max_Input_Length)

	edit(&dev, .Select_All)
	insert_text(&dev, "inspect q suffix")
	set_input_caret(&dev, len("inspect q"))
	probe.candidates = {"q\nline", "q\rcarriage", "q\ttab", "q\x00nul", "q\x01control", "q\xc3"}
	revision = dev.edit_revision
	testing.expect(t, !complete(&dev))
	testing.expect(t, input_text(&dev) == "inspect q suffix" && dev.edit_revision == revision)
	testing.expect(t, dev.input_caret == len("inspect q") && dev.input_anchor == dev.input_caret)
}

@(test)
argument_completion_rejects_invalid_quotes_without_calling_the_provider :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	for input in ([7]string{
		`inspect "bad\q`, `inspect "bad\uZZZZ`, `inspect "bad\q" x`,
		`inspect "bad\'`, `inspect "closed"junk`, `inspect "closed"junk x`,
		`inspect "bad\`,
	}) {
		probe := Argument_Completion_Probe {t = t, candidates = {"candidate"}}
		dev := init()
		dev.user_data = &probe
		register(&dev, "inspect", "", argument_completion_handler, argument_completion_provider)
		insert_text(&dev, input)
		revision := dev.edit_revision
		testing.expect(t, !complete(&dev))
		testing.expect(t, input_text(&dev) == input && dev.edit_revision == revision)
		testing.expectf(t, probe.calls == 0, "Invalid argument must not invoke the provider: %s", input)
	}
}

@(test)
argument_completion_leaves_unprovided_commands_and_selections_untouched :: proc(t: ^testing.T) {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	dev := init()
	register(&dev, "plain", "", argument_completion_handler)
	insert_text(&dev, "plain argument")
	revision := dev.edit_revision
	testing.expect(t, !complete(&dev))
	testing.expect(t, input_text(&dev) == "plain argument" && dev.edit_revision == revision)
	probe := Argument_Completion_Probe {t = t, prefix = "c", candidates = {"cat"}}
	dev.user_data = &probe
	register(&dev, "inspect", "", argument_completion_handler, argument_completion_provider)
	edit(&dev, .Select_All)
	insert_text(&dev, "inspect c")
	set_input_caret(&dev, len("inspect "))
	set_input_caret(&dev, dev.input_len, true)
	revision = dev.edit_revision
	testing.expect(t, !complete(&dev))
	testing.expect(t, input_text(&dev) == "inspect c" && dev.edit_revision == revision)
	testing.expect(t, probe.calls == 0)
	set_input_caret(&dev, dev.input_len)
	dev.selection_target = .Output
	revision = dev.edit_revision
	testing.expect(t, !complete(&dev))
	testing.expect(t, input_text(&dev) == "inspect c" && dev.edit_revision == revision)
	testing.expect(t, probe.calls == 0)
}
