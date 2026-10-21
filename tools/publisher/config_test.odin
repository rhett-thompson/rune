package main

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:testing"

CONFIG_TEST_BASE :: `{"id":"my-game","name":"My Game","version":"0.1.0+1","executable":"my-game","targets":["windows-amd64","linux-amd64"],"content":["project.json","input/","scenes/","assets/My Game.png"]}`

@(test)
config_accepts_metadata_content_and_typed_compiler_options :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	source := config_test_replace(CONFIG_TEST_BASE, `"content":`, `"$schema":"schemas/publish.schema.json","licenses":["LICENSE","licenses/"],"build":{"collections":{"shared":"../Shared Code","_utils":"third_party\\utils"},"defines":{"MULTIPLAYER":true,"NUMBER":17,"FRACTION":0.5,"TITLE":"quoted \"game\""},"extra_linker_flags":"-lm -ldl"},"content":`)
	config, error := decode_config(transmute([]u8)source)
	if !testing.expect(t, error == "", error) {return}
	testing.expect(t, config.id == "my-game" && config.name == "My Game" && config.version == "0.1.0+1" && config.executable == "my-game")
	testing.expect(t, len(config.targets) == 2 && config.targets[1] == "linux-amd64")
	testing.expect(t, len(config.content) == 4 && config.content[3] == "assets/My Game.png" && len(config.licenses) == 2)
	testing.expect(t, config.build.collections["shared"] == "../Shared Code" && config.build.extra_linker_flags == "-lm -ldl")
	testing.expect(t, config.build.defines["MULTIPLAYER"].(json.Boolean) && config.build.defines["NUMBER"].(json.Integer) == 17)
	testing.expect(t, config.build.defines["TITLE"].(json.String) == `quoted "game"`)
	minimal, minimal_error := decode_config(transmute([]u8)string(CONFIG_TEST_BASE))
	testing.expect(t, minimal_error == "" && len(minimal.licenses) == 0 && len(minimal.build.collections) == 0 && len(minimal.build.defines) == 0)
}

@(test)
config_rejects_malformed_unknown_and_reserved_fields :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	for source in ([]string{
		``, `{`, `[]`, `null`, `{"id":"game"}`, `{"":"ignored"}`,
		CONFIG_TEST_BASE + ` {}`, CONFIG_TEST_BASE + "\x00ignored",
		config_test_replace(CONFIG_TEST_BASE, `"id":"my-game",`, `"id":"my-game","id":"other",`),
		config_test_replace(CONFIG_TEST_BASE, `"id":"my-game",`, `"id":"my-game","unknown":true,`),
		config_test_replace(CONFIG_TEST_BASE, `"id":"my-game",`, `"id":"my-game","$schema":42,`),
		config_test_replace(CONFIG_TEST_BASE, `"id":"my-game",`, `"id":"my-game",/* comment */`),
		config_test_replace(CONFIG_TEST_BASE, `"id":"my-game",`, `id:"my-game",`),
		config_test_replace(CONFIG_TEST_BASE, `"id":"my-game",`, `"id":"my-game","build":{"unknown":true},`),
		config_test_replace(CONFIG_TEST_BASE, `"id":"my-game",`, `"id":"my-game","build":{"collections":{"rune":"../rune"}},`),
		config_test_replace(CONFIG_TEST_BASE, `"id":"my-game",`, `"id":"my-game","build":{"collections":{"r3d":"../r3d"}},`),
		config_test_replace(CONFIG_TEST_BASE, `"id":"my-game",`, `"id":"my-game","build":{"collections":{"bad-name":"shared"}},`),
		config_test_replace(CONFIG_TEST_BASE, `"id":"my-game",`, `"id":"my-game","build":{"collections":{"shared":"C:/shared"}},`),
		config_test_replace(CONFIG_TEST_BASE, `"id":"my-game",`, `"id":"my-game","build":{"defines":{"RUNE_PLAYER":false}},`),
		config_test_replace(CONFIG_TEST_BASE, `"id":"my-game",`, `"id":"my-game","build":{"defines":{"RAYLIB_SHARED":true}},`),
		config_test_replace(CONFIG_TEST_BASE, `"id":"my-game",`, `"id":"my-game","build":{"defines":{"OPTION":null}},`),
		config_test_replace(CONFIG_TEST_BASE, `"id":"my-game",`, `"id":"my-game","build":{"defines":{"OPTION":[]}},`),
		config_test_replace(CONFIG_TEST_BASE, `"id":"my-game",`, `"id":"my-game","build":{"defines":{"OPTION":"before\u0000after"}},`),
		config_test_replace(CONFIG_TEST_BASE, `"id":"my-game",`, `"id":"my-game","build":{"extra_linker_flags":[]},`),
		config_test_replace(CONFIG_TEST_BASE, `"id":"my-game",`, `"id":"my-game","build":{"extra_linker_flags":"-lm\n-ldl"},`),
		config_test_replace(CONFIG_TEST_BASE, `"linux-amd64"`, `"windows-amd64"`),
		config_test_replace(CONFIG_TEST_BASE, `"linux-amd64"`, `"macos-arm64"`),
		config_test_replace(CONFIG_TEST_BASE, `"linux-amd64"]`, `"linux-amd64",]`),
		config_test_replace(CONFIG_TEST_BASE, `"my-game","name"`, `"my-game",,"name"`),
	}) {
		_, error := decode_config(transmute([]u8)source)
		testing.expect(t, error != "", source)
	}
}

@(test)
config_enforces_portable_staged_paths_and_output_names :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	for path in ([]string{"", "/", "/assets", "\\assets", "C:/assets", "../assets", "assets/../outside", "./assets", "assets//nested", "assets\\nested", "assets/thing.", "assets/thing ", "assets/CON", "assets/NUL.txt", "COM1/data", "Lpt9.dll", "assets/CONIN$", "assets/CONOUT$.txt", "assets/COM¹", "assets/LPT².txt", "assets/a:b", "assets/a?b", "assets/a*b", "assets/a|b", "assets/a<b", "assets/a\x00b", "assets/a\nb", "assets/a\x7fb"}) {
		testing.expect(t, !config_content_path(path), path)
	}
	for path in ([]string{"project.json", "input/", "folder with spaces/nested/file.png", "assets/étoile.png", ".hidden/file", "com0.txt", "LPT10/file"}) {testing.expect(t, config_content_path(path), path)}
	for component in ([]string{"", ".", "..", "my game", "game.", "../game", "NUL", "con.txt", "lpt1", "game:one", "game/one"}) {testing.expect(t, !config_filename(component), component)}
	for component in ([]string{"game", "my-game", "org.example.game", "game_2", "0.1.0-beta"}) {testing.expect(t, config_filename(component), component)}
	_, error := decode_config(transmute([]u8)config_test_replace(CONFIG_TEST_BASE, `"executable":"my-game"`, `"executable":"my-game.exe"`))
	testing.expect(t, error != "", "executable is extensionless")
	_, error = decode_config(transmute([]u8)config_test_replace(CONFIG_TEST_BASE, `"executable":"my-game"`, `"executable":"LiCeNsEs"`))
	testing.expect(t, error != "", "executable cannot collide with the package notices directory")
	_, error = decode_config(transmute([]u8)config_test_replace(CONFIG_TEST_BASE, `"name":"My Game"`, `"name":"   "`))
	testing.expect(t, error != "", "title cannot be whitespace")
}

@(test)
config_strict_json_rejects_trailing_commas_and_non_json_whitespace :: proc(t: ^testing.T) {
	for text in ([]string{`{"a":1,}`, `[1,]`, `{"a":1}[]`, `{"a":01}`, `{"a":NaN}`, `{"a":9223372036854775808}`, `{"a":-9223372036854775809}`, `{"a":1e999}`, "{\v\"a\":1}", `{"a":"bad\q"}`, `{"a":"raw` + "\n" + `newline"}`}) {testing.expect(t, !config_json_syntax_valid(text), text)}
	for text in ([]string{`{}`, `[]`, `{"a":[true,false,null,2,-1.5e+2,"a\n\"b"]}`, " \t\r\n{}\n"}) {testing.expect(t, config_json_syntax_valid(text), text)}
}

config_test_replace :: proc(source, old, replacement: string) -> string {
	result, _ := strings.replace_all(source, old, replacement)
	return result
}
