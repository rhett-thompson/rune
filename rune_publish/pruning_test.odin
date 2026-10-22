package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

pruning_test_files :: proc(t: ^testing.T, root: string, config: Config) -> []Publish_File {
	files, error := collect_content(root, config, "game.exe")
	testing.expect(t, error == "", error)
	return files
}

pruning_test_contains :: proc(files: []Publish_File, path: string) -> bool {
	for file in files {if file.destination == path {return true}}
	return false
}

@(test)
pruning_keeps_live_files_and_ignores_unreferenced_broken_documents :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root := content_test_root(t)
	defer content_test_cleanup(root)
	content_test_game(t, root)
	content_test_write(t, root, "project.json", `{"name":"Content test","window":{},"startup_scene":"scenes/main.scene.json","input":"input.json"}`)
	content_test_write(t, root, "input.json", `{}`)
	content_test_write(t, root, "scenes/main.scene.json", `{"name":"Main","entities":[{"components":{"SpriteRenderer":{"texture":"assets/keep.png"}}}]}`)
	content_test_write(t, root, "assets/keep.png", "live texture")
	content_test_write(t, root, "assets/unused.material.json", `{"texture":"missing.png"}`)
	content_test_write(t, root, "assets/invalid.scene.json", "not JSON")
	config := Config{content={"project.json", "input.json", "scenes/", "assets/"}}
	files := pruning_test_files(t, root, config)
	disabled, report, error := prune_content(root, config, files)
	testing.expect(t, error == "" && !report.enabled && len(disabled) == len(files), error)
	config.prune.enabled = true
	retained: []Publish_File
	retained, report, error = prune_content(root, config, files)
	testing.expect(t, error == "", error)
	testing.expect(t, report.enabled && report.candidate_files == 6 && report.retained_files == 4 && report.pruned_files == 2)
	testing.expect(t, report.candidate_bytes == report.retained_bytes+report.pruned_bytes && report.pruned_bytes > 0)
	testing.expect(t, pruning_test_contains(retained, "project.json") && pruning_test_contains(retained, "input.json") && pruning_test_contains(retained, "assets/keep.png"))
	testing.expect(t, !pruning_test_contains(retained, "assets/unused.material.json") && !pruning_test_contains(retained, "assets/invalid.scene.json"))
	testing.expect(t, len(report.pruned) == 2 && report.pruned[0] == "assets/invalid.scene.json" && report.pruned[1] == "assets/unused.material.json")
	testing.expect(t, len(report.roots) == 1 && report.roots[0] == "project.json")
}

@(test)
pruning_traverses_prefab_cycles_model_data_and_runtime_material_defaults :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root := content_test_root(t)
	defer content_test_cleanup(root)
	content_test_game(t, root)
	content_test_write(t, root, "scenes/main.scene.json", `{"name":"Main","entities":[{"prefab":"../prefabs/a.prefab.json"}]}`)
	content_test_write(t, root, "prefabs/a.prefab.json", `{"prefab":"b.prefab.json"}`)
	content_test_write(t, root, "prefabs/b.prefab.json", `{"prefab":"a.prefab.json","components":{"ModelRenderer":{"model":"assets/model.gltf"}}}`)
	content_test_write(t, root, "assets/model.gltf", `{"asset":{"version":"2.0"},"buffers":[{"uri":"model.bin"}],"images":[{"uri":"embedded%20image.png"},{"uri":"data:image/png;base64,AA=="}]}`)
	content_test_write(t, root, "assets/model.bin", "model buffer")
	content_test_write(t, root, "assets/embedded image.png", "embedded image")
	content_test_write(t, root, "assets/model.gltf.materials.json", `{"materials":{"0":"assets/default.material.json"}}`)
	content_test_write(t, root, "assets/default.material.json", `{"albedo":"assets/default.png","surface_shader":"assets/default.glsl"}`)
	content_test_write(t, root, "assets/default.png", "default image")
	content_test_write(t, root, "assets/default.glsl", "shader")
	content_test_write(t, root, "assets/unused.png", "unused")
	config := Config{content={"project.json", "scenes/", "prefabs/", "assets/"}, prune={enabled=true}}
	files := pruning_test_files(t, root, config)
	retained, report, error := prune_content(root, config, files)
	testing.expect(t, error == "", error)
	testing.expect(t, report.pruned_files == 1 && report.pruned[0] == "assets/unused.png")
	for path in ([]string{"prefabs/a.prefab.json", "prefabs/b.prefab.json", "assets/model.bin", "assets/embedded image.png", "assets/model.gltf.materials.json", "assets/default.material.json", "assets/default.png", "assets/default.glsl"}) {
		testing.expect(t, pruning_test_contains(retained, path), path)
	}
	for i := 1; i < len(retained); i += 1 {testing.expect(t, retained[i-1].destination < retained[i].destination, "retained inventory must be deterministic")}
	// Runtime sidecars are optional, but existing defaults cannot be silently
	// excluded from the candidate inventory.
	without_sidecar := make([dynamic]Publish_File)
	for file in files {if file.destination != "assets/model.gltf.materials.json" {append(&without_sidecar, file)}}
	_, _, error = prune_content(root, config, without_sidecar[:])
	testing.expect(t, strings.contains(error, "model.gltf.materials.json"), error)
}

@(test)
pruning_honors_code_roots_manifest_edges_directories_and_licenses :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root := content_test_root(t)
	defer content_test_cleanup(root)
	content_test_game(t, root)
	content_test_write(t, root, "code/loaded.scene.json", `{"name":"Loaded","entities":[{"components":{"SpriteAnimator":{"animation":"assets/live.animation.json"},"TilemapRenderer":{"tileset":"assets/live.tileset.json"},"Terrain":{"asset":"assets/live.terrain.json"},"MeshRenderer":{"material":"assets/primitive.material.json"},"SphereRenderer":{"material":"assets/sphere.material.json"}}}]}`)
	content_test_write(t, root, "assets/live.animation.json", `{"texture":"assets/animation.png"}`)
	content_test_write(t, root, "assets/live.tileset.json", `{"texture":"assets/tiles.png"}`)
	content_test_write(t, root, "assets/live.terrain.json", `{"heightmap":"assets/height.r16","material":"assets/terrain.material.json"}`)
	content_test_write(t, root, "assets/terrain.material.json", `{"normal":"assets/normal.png"}`)
	content_test_write(t, root, "assets/primitive.material.json", `{"texture":"assets/primitive.png"}`)
	content_test_write(t, root, "assets/sphere.material.json", `{"texture":"assets/sphere.png"}`)
	content_test_write(t, root, "assets/primitive.png", "primitive texture")
	content_test_write(t, root, "assets/sphere.png", "sphere texture")
	for path in ([]string{"assets/animation.png", "assets/tiles.png", "assets/height.r16", "assets/normal.png"}) {content_test_write(t, root, path, "asset")}
	content_test_write(t, root, "assets/custom/model.obj", "mtllib model.mtl\n")
	content_test_write(t, root, "assets/custom/model.mtl", "map_Kd texture.png\n")
	content_test_write(t, root, "assets/custom/texture.png", "custom texture")
	content_test_write(t, root, "data/world.json", `{"game_specific":true}`)
	content_test_write(t, root, "data/other.json", `{}`)
	content_test_write(t, root, "data/unused.json", `{}`)
	content_test_write(t, root, "licenses/nested/game.txt", "Game notice")
	content_test_write(t, root, "licenses/other.txt", "Asset notice")
	testing.expect(t, os.make_directory(fmt.aprintf("%s/assets/empty", root)) == nil)
	manifest := `{"version":1,"roots":["data/world.json"],"dependencies":{"data/world.json":["data/other.json","assets/custom/"],"data/other.json":["data/world.json"],"data/unused.json":["missing-dead-dependency.png"]}}`
	content_test_write(t, root, "publish-deps.json", manifest)
	config := Config{content={"project.json", "scenes/", "code/", "assets/", "data/"}, licenses={"licenses/"}, prune={enabled=true, roots={"code/", "assets/empty/"}, manifests={"publish-deps.json"}}}
	retained, report, error := prune_content(root, config, pruning_test_files(t, root, config))
	testing.expect(t, error == "", error)
	for path in ([]string{"code/loaded.scene.json", "assets/live.animation.json", "assets/animation.png", "assets/tiles.png", "assets/height.r16", "assets/normal.png", "assets/primitive.material.json", "assets/primitive.png", "assets/sphere.material.json", "assets/sphere.png", "assets/custom/model.mtl", "assets/custom/texture.png", "data/world.json", "data/other.json", "licenses/nested/game.txt", "licenses/other.txt", "assets/empty"}) {
		testing.expect(t, pruning_test_contains(retained, path), path)
	}
	testing.expect(t, !pruning_test_contains(retained, "data/unused.json") && !pruning_test_contains(retained, "publish-deps.json"))
	testing.expect(t, len(report.manifests) == 1 && report.manifests[0].path == "publish-deps.json" && report.manifests[0].sha256 == hash_bytes(transmute([]u8)manifest))
	for i := 1; i < len(report.roots); i += 1 {testing.expect(t, report.roots[i-1] < report.roots[i])}
}

@(test)
pruning_rejects_missing_live_dependencies_wrong_case_and_escaping_paths :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root := content_test_root(t)
	defer content_test_cleanup(root)
	content_test_game(t, root)
	content_test_write(t, root, "assets/texture.png", "texture")
	config := Config{content={"project.json", "scenes/", "assets/"}, prune={enabled=true}}
	for reference in ([]string{"assets/missing.png", "assets/TEXTURE.png", "../outside.png", "/absolute.png", "C:/absolute.png", "prefab://../../outside.png", "assets/aux.png", "assets/"}) {
		scene, _ := strings.replace_all(`{"name":"Main","entities":[{"components":{"SpriteRenderer":{"texture":"$REFERENCE"}}}]}`, "$REFERENCE", reference)
		content_test_write(t, root, "scenes/main.scene.json", scene)
		_, _, error := prune_content(root, config, pruning_test_files(t, root, config))
		testing.expect(t, error != "", reference)
	}
	content_test_game(t, root)
	for path in ([]string{"missing/", "ASSETS/", "../assets/", "assets/TEXTURE.png"}) {
		config.prune.roots = {path}
		_, _, error := prune_content(root, config, pruning_test_files(t, root, config))
		testing.expect(t, error != "", path)
	}
	config.prune.roots = nil
	config.prune.manifests = {"deps.json"}
	content_test_write(t, root, "deps.json", `{"version":1,"dependencies":{"project.json":["missing-live.bin"]}}`)
	_, _, error := prune_content(root, config, pruning_test_files(t, root, config))
	testing.expect(t, strings.contains(error, "missing-live.bin"), error)
}

@(test)
pruning_rejects_invalid_manifest_grammar_and_metadata_paths :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root := content_test_root(t)
	defer content_test_cleanup(root)
	content_test_game(t, root)
	config := Config{content={"project.json", "scenes/"}, prune={enabled=true, manifests={"deps.json"}}}
	for manifest in ([]string{
		`{"version":1,"unknown":true}`, `{"version":1,"version":1}`, `{"version":1,}`, `{"version":1} trailing`, `[]`, `{"version":2}`, `{"version":1.0}`,
		`{"version":1,"roots":["../outside"]}`, `{"version":1,"roots":["scenes/MAIN.scene.json"]}`, `{"version":1,"roots":["project.json","project.json"]}`,
		`{"version":1,"dependencies":{"missing.json":[]}}`, `{"version":1,"dependencies":{"PROJECT.json":[]}}`, `{"version":1,"dependencies":{"project.json":["C:/outside"]}}`,
		`{"version":1,"inputs":{"project.json":"bad-digest"}}`, `{"version":1,"inputs":[]}`,
	}) {
		content_test_write(t, root, "deps.json", manifest)
		_, _, error := prune_content(root, config, pruning_test_files(t, root, config))
		testing.expect(t, error != "", manifest)
	}
	content_test_write(t, root, "deps.json", `{"version":1}`)
	for path in ([]string{"DEPS.json", "../deps.json", "scenes/"}) {
		config.prune.manifests = {path}
		_, _, error := prune_content(root, config, pruning_test_files(t, root, config))
		testing.expect(t, error != "", path)
	}
}

@(test)
pruning_checks_source_input_hashes_and_directory_inventory_changes :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root := content_test_root(t)
	defer content_test_cleanup(root)
	content_test_game(t, root)
	content_test_write(t, root, "src/z.odin", "package game\n")
	content_test_write(t, root, "src/nested/a.odin", "package game\nmain :: proc() {}\n")
	config := Config{content={"project.json", "scenes/"}, prune={enabled=true, manifests={"deps.json"}}}
	project_digest, error := prune_input_digest(root, "project.json")
	testing.expect(t, error == "", error)
	source_digest: string
	source_digest, error = prune_input_digest(root, "src/")
	testing.expect(t, error == "", error)
	expected_data := fmt.aprintf("nested/a.odin%c%s\nz.odin%c%s\n", u8(0), hash_bytes(transmute([]u8)string("package game\nmain :: proc() {}\n")), u8(0), hash_bytes(transmute([]u8)string("package game\n")))
	testing.expect(t, source_digest == hash_bytes(transmute([]u8)expected_data), "directory digest must follow the portable documented format")
	manifest, _ := strings.replace_all(`{"version":1,"inputs":{"project.json":"$PROJECT","src/":"$SOURCE"}}`, "$PROJECT", project_digest)
	manifest, _ = strings.replace_all(manifest, "$SOURCE", source_digest)
	content_test_write(t, root, "deps.json", manifest)
	_, _, error = prune_content(root, config, pruning_test_files(t, root, config))
	testing.expect(t, error == "", error)
	content_test_write(t, root, "src/new.odin", "package game\n")
	_, _, error = prune_content(root, config, pruning_test_files(t, root, config))
	testing.expect(t, strings.contains(error, "regenerate") && strings.contains(error, "src/"), error)
	new_source, _ := filepath.join({root, "src/new.odin"})
	testing.expect(t, os.remove(new_source) == nil)
	content_test_write(t, root, "src/z.odin", "package changed\n")
	_, _, error = prune_content(root, config, pruning_test_files(t, root, config))
	testing.expect(t, strings.contains(error, "regenerate"), error)
	_, error = prune_input_digest(root, "SRC/")
	testing.expect(t, strings.contains(error, "case"), error)
}

@(test)
pruning_source_inputs_and_manifests_reject_linked_ancestors :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		arena: mem.Dynamic_Arena
		mem.dynamic_arena_init(&arena)
		defer mem.dynamic_arena_destroy(&arena)
		context.allocator = mem.dynamic_arena_allocator(&arena)
		root := content_test_root(t)
		defer content_test_cleanup(root)
		content_test_game(t, root)
		content_test_write(t, root, "metadata/deps.json", `{"version":1}`)
		link, _ := filepath.join({root, "linked"})
		target, _ := filepath.join({root, "metadata"})
		testing.expect(t, os.symlink(target, link) == nil)
		config := Config{content={"project.json", "scenes/"}, prune={enabled=true, manifests={"linked/deps.json"}}}
		_, _, error := prune_content(root, config, pruning_test_files(t, root, config))
		testing.expect(t, strings.contains(error, "symbolic"), error)
		_, error = prune_input_digest(root, "linked/")
		testing.expect(t, strings.contains(error, "symbolic"), error)
	}
}

@(test)
pruning_keeps_licenses_inside_content_without_duplicate_candidates :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root := content_test_root(t)
	defer content_test_cleanup(root)
	content_test_game(t, root)
	content_test_write(t, root, "assets/notices/OFL.txt", "Font license")
	content_test_write(t, root, "assets/notices/LICENSE.txt", "Asset license")
	content_test_write(t, root, "assets/unused.png", "unused")
	config := Config{content={"project.json", "scenes/", "assets/"}, licenses={"assets/notices/OFL.txt", "assets/notices/"}, prune={enabled=true}}
	files := pruning_test_files(t, root, config)
	testing.expect(t, len(files) == 5, "asset-contained licenses must appear once")
	retained, report, error := prune_content(root, config, files)
	testing.expect(t, error == "", error)
	testing.expect(t, report.retained_files == 4 && report.pruned_files == 1)
	testing.expect(t, pruning_test_contains(retained, "assets/notices/OFL.txt") && pruning_test_contains(retained, "assets/notices/LICENSE.txt"))
	config.content = {"project.json", "scenes/", "assets/", "assets/notices/OFL.txt"}
	_, error = collect_content(root, config, "game.exe")
	testing.expect(t, error != "", "ordinary overlapping content must still fail")
	config.content = {"project.json", "scenes/", "assets/"}
	config.licenses = {"ASSETS/notices/OFL.txt"}
	_, error = collect_content(root, config, "game.exe")
	testing.expect(t, error != "", "license overlap cannot bypass exact case")
	// Including one notice as content and its parent as a license must merge
	// overlapping children while still collecting the other notice.
	config.content = {"project.json", "scenes/", "assets/notices/OFL.txt"}
	config.licenses = {"assets/notices/"}
	files = pruning_test_files(t, root, config)
	testing.expect(t, len(files) == 4)
}
