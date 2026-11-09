package main

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "rune:assetcatalog"

@(test)
catalog_planning_packages_runtime_lookup_with_transitive_dependencies :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root := content_test_root(t)
	defer content_test_cleanup(root)
	content_test_game(t, root)
	content_test_write(t, root, "assets.json", `{"$schema":"schemas/assetcatalog.schema.json","version":1,"assets":{"scene.extra":"scenes/extra.scene.json","data.level":"data/level.json"},"directories":{"dir.audio":"assets/audio"},"dependencies":{"data/level.json":["data/patrol.navmesh.json"]}}`)
	content_test_write(t, root, "scenes/extra.scene.json", `{"entities":[{"prefab":"../prefabs/extra.prefab.json"}]}`)
	content_test_write(t, root, "prefabs/extra.prefab.json", `{"components":{"SpriteRenderer":{"texture":"assets/extra.png"}}}`)
	content_test_write(t, root, "assets/extra.png", "scene dependency")
	content_test_write(t, root, "assets/audio/wind.wav", "named directory child")
	content_test_write(t, root, "assets/unused.png", "unused")
	content_test_write(t, root, "data/level.json", "custom level")
	content_test_write(t, root, "data/patrol.navmesh.json", "custom dependency")
	content_test_write(t, root, "data/unused.bin", "unused")
	plan, error := plan_content(root, {}, "game.exe")
	if !testing.expect(t, error == "", error) {return}
	for path in ([]string{"assets.json", "scenes/main.scene.json", "scenes/extra.scene.json", "prefabs/extra.prefab.json", "assets/extra.png", "assets/audio/wind.wav", "data/level.json", "data/patrol.navmesh.json"}) {
		testing.expect(t, catalog_test_contains(plan.files, path), path)
	}
	testing.expect(t, !catalog_test_contains(plan.files, "assets/unused.png") && !catalog_test_contains(plan.files, "data/unused.bin"))
	stage, _ := filepath.join({root, "stage"})
	if !testing.expect(t, os.make_directory(stage) == nil) {return}
	copy_error := copy_publish_files(plan.files, stage)
	if !testing.expect(t, copy_error == "", copy_error) {return}
	catalog, catalog_error := assetcatalog.open(stage)
	if !testing.expect(t, catalog_error == "", catalog_error) {return}
	defer assetcatalog.destroy(&catalog)
	for key in ([]string{"scene.extra", "data.level", "dir.audio/wind.wav"}) {
		path, found := assetcatalog.load(&catalog, key)
		filename, _ := filepath.join({stage, path})
		testing.expect(t, found && os.is_file(filename), key)
	}
}

@(test)
catalog_planning_requires_named_files_and_directories_to_match_source_types :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root := content_test_root(t)
	defer content_test_cleanup(root)
	content_test_game(t, root)
	content_test_write(t, root, "assets/audio/wind.wav", "file in nonempty directory")
	for invalid in ([]struct {catalog, error_text: string}{
		{`{"version":1,"assets":{"audio":"assets/audio"}}`, "regular file"},
		{`{"version":1,"assets":{"audio":"assets/audio/wind.wav/"}}`, "regular file"},
		{`{"version":1,"assets":{},"directories":{"audio":"assets/audio/wind.wav"}}`, "directory"},
		{`{"version":1,"assets":{},"directories":{"audio":"assets/Audio"}}`, "case"},
		{`{"version":1,"assets":{"outside":"../outside.png"}}`, "relative"},
	}) {
		content_test_write(t, root, "assets.json", invalid.catalog)
		_, error := plan_content(root, {}, "game.exe")
		testing.expect(t, strings.contains(error, invalid.error_text), error)
	}
}
