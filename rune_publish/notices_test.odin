package main

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
publisher_notices_require_private_decoder_license_and_provenance :: proc(t: ^testing.T) {
	arena:mem.Dynamic_Arena;mem.dynamic_arena_init(&arena);defer mem.dynamic_arena_destroy(&arena)
	context.allocator=mem.dynamic_arena_allocator(&arena);context.temp_allocator=context.allocator
	root:=main_test_root(t);if root=="" {return};defer main_test_cleanup(root)
	engine:=main_test_write(t,root,"engine/LICENSE","notice")
	engine=strings.trim_suffix(engine,"/LICENSE")
	engine=strings.trim_suffix(engine,"\\LICENSE")
	for relative in ([]string{
		"THIRD_PARTY.md","third_party/clay/LICENSE.md","third_party/r3d-odin/LICENSE",
		"third_party/r3d-importer/LICENSE.assimp","third_party/r3d-importer/LICENSE.r3d",
		"third_party/r3d-importer/LICENSE.raylib","third_party/r3d-importer/LICENSE.raymath","third_party/r3d-importer/LICENSE.uthash",
		"third_party/r3d-importer/README.md","third_party/r3d-shadows/README.md",
		"third_party/rune-image/LICENSE.stb_image","third_party/rune-image/README.md",
		"third_party/rune-image/sources.json","third_party/rune-image/thread-local-png-error.patch",
	}) {_=main_test_write(t,engine,relative,"notice")}
	odin:=main_test_write(t,root,"odin/LICENSE","notice")
	odin=strings.trim_suffix(odin,"/LICENSE");odin=strings.trim_suffix(odin,"\\LICENSE")
	for relative in ([]string{"vendor/raylib/LICENSE","vendor/box2d/LICENSE","vendor/stb/src/stb_image.h",
		"vendor/box3d/src/include/box3d/box3d.h","vendor/box3d/src/src/verstable.h"}) {_=main_test_write(t,odin,relative,"notice")}
	files,failure:=collect_engine_notices(engine,odin)
	if !testing.expect(t,failure=="",failure) {return}
	for relative in ([]string{"LICENSE.stb_image","README.md","sources.json","thread-local-png-error.patch"}) {
		expected:=fmt.tprintf("licenses/rune/third_party/rune-image/%s",relative)
		found:=false;for file in files {if file.destination==expected {found=true;break}}
		testing.expect(t,found,"private decoder attribution and provenance are included in the published notice set")
	}
	license:=main_test_write(t,engine,"third_party/rune-image/LICENSE.stb_image","notice")
	assert(os.remove(license)==nil)
	_,failure=collect_engine_notices(engine,odin)
	testing.expect(t,strings.contains(failure,"LICENSE.stb_image"),"a missing private decoder notice fails publishing")
}

@(test)
publisher_native_source_pins_include_private_image_decoder :: proc(t: ^testing.T) {
	arena:mem.Dynamic_Arena;mem.dynamic_arena_init(&arena);defer mem.dynamic_arena_destroy(&arena)
	context.allocator=mem.dynamic_arena_allocator(&arena);context.temp_allocator=context.allocator
	root:=main_test_root(t);if root=="" {return};defer main_test_cleanup(root)
	for relative in ([]string{"third_party/r3d-importer/sources.json","third_party/r3d-shadows/sources.json","third_party/rune-image/sources.json"}) {
		_=main_test_write(t,root,relative,`{"source":"pinned native source","altered_header_sha256":"recorded hash"}`)
	}
	pins:=native_source_pins(root)
	value,found:=pins["third_party/rune-image/sources.json"]
	if !testing.expect(t,found && len(pins)==3,"the manifest preserves all native source-pin documents") {return}
	object,valid:=value.(json.Object)
	testing.expect(t,valid && object["altered_header_sha256"].(json.String)=="recorded hash","private decoder pin fields survive collection unchanged")
}
