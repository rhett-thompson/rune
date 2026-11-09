package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

CATALOG_TEST_EMPTY :: `{"version":1,"assets":{}}`

catalog_test_contains :: proc(files: []Publish_File, path: string) -> bool {
	for file in files {if file.destination == path {return true}}
	return false
}

@(test)
catalog_planning_keeps_project_dependencies_and_ignores_unreferenced_documents :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root := content_test_root(t)
	defer content_test_cleanup(root)
	content_test_game(t, root)
	content_test_write(t, root, "assets.json", CATALOG_TEST_EMPTY)
	content_test_write(t, root, "project.json", `{"name":"Content test","window":{},"startup_scene":"scenes/main.scene.json","input":"input.json"}`)
	content_test_write(t, root, "input.json", `{}`)
	content_test_write(t, root, "scenes/main.scene.json", `{"name":"Main","entities":[{"components":{"SpriteRenderer":{"texture":"assets/keep.png"}}}]}`)
	content_test_write(t, root, "assets/keep.png", "live texture")
	content_test_write(t, root, "assets/unused.material.json", `{"texture":"missing.png"}`)
	content_test_write(t, root, "assets/invalid.scene.json", "not JSON")
	plan, error := plan_content(root, {}, "game.exe")
	testing.expect(t, error == "", error)
	testing.expect(t, len(plan.files) == 5)
	for path in ([]string{"project.json", "assets.json", "scenes/main.scene.json", "input.json", "assets/keep.png"}) {
		testing.expect(t, catalog_test_contains(plan.files, path), path)
	}
}

@(test)
catalog_planning_traverses_prefab_cycles_model_data_and_runtime_material_defaults :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root := content_test_root(t)
	defer content_test_cleanup(root)
	content_test_game(t, root)
	content_test_write(t, root, "assets.json", CATALOG_TEST_EMPTY)
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
	plan, error := plan_content(root, {}, "game.exe")
	testing.expect(t, error == "", error)
	testing.expect(t, !catalog_test_contains(plan.files, "assets/unused.png"))
	for path in ([]string{"prefabs/a.prefab.json", "prefabs/b.prefab.json", "assets/model.bin", "assets/embedded image.png", "assets/model.gltf.materials.json", "assets/default.material.json", "assets/default.png", "assets/default.glsl"}) {
		testing.expect(t, catalog_test_contains(plan.files, path), path)
	}
	for i := 1; i < len(plan.files); i += 1 {
		testing.expect(t, plan.files[i-1].destination < plan.files[i].destination, "package inventory must be deterministic")
	}
}

@(test)
catalog_planning_follows_directory_contents_custom_edges_and_licenses :: proc(t: ^testing.T) {
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
	catalog := `{"version":1,"assets":{"world":"data/world.json"},"directories":{"scenes":"code/","empty":"assets/empty"},"dependencies":{"data/world.json":["data/other.json","assets/custom/"],"data/other.json":["data/world.json"],"data/unused.json":["missing-dead-dependency.png"]}}`
	content_test_write(t, root, "assets.json", catalog)
	plan, error := plan_content(root, Config{licenses={"licenses/"}}, "game.exe")
	testing.expect(t, error == "", error)
	for path in ([]string{"assets.json", "code/loaded.scene.json", "assets/live.animation.json", "assets/animation.png", "assets/tiles.png", "assets/height.r16", "assets/normal.png", "assets/primitive.material.json", "assets/primitive.png", "assets/sphere.material.json", "assets/sphere.png", "assets/custom/model.mtl", "assets/custom/texture.png", "data/world.json", "data/other.json", "licenses/nested/game.txt", "licenses/other.txt", "assets/empty"}) {
		testing.expect(t, catalog_test_contains(plan.files, path), path)
	}
	testing.expect(t, !catalog_test_contains(plan.files, "data/unused.json"))
	testing.expect(t, plan.catalog_sha256 == hash_bytes(transmute([]u8)catalog))
	if testing.expect(t, len(plan.directories) == 4) {
		testing.expect(t, plan.directories[0] == "assets/custom" && plan.directories[1] == "assets/empty" && plan.directories[2] == "code" && plan.directories[3] == "licenses")
	}
}

@(test)
catalog_planning_rejects_missing_live_dependencies_wrong_case_and_escaping_paths :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root := content_test_root(t)
	defer content_test_cleanup(root)
	content_test_game(t, root)
	content_test_write(t, root, "assets.json", CATALOG_TEST_EMPTY)
	content_test_write(t, root, "assets/texture.png", "texture")
	for reference in ([]string{"assets/missing.png", "assets/TEXTURE.png", "../outside.png", "/absolute.png", "C:/absolute.png", "prefab://../../outside.png", "assets/aux.png", "assets/"}) {
		scene, _ := strings.replace_all(`{"name":"Main","entities":[{"components":{"SpriteRenderer":{"texture":"$REFERENCE"}}}]}`, "$REFERENCE", reference)
		content_test_write(t, root, "scenes/main.scene.json", scene)
		_, error := plan_content(root, {}, "game.exe")
		testing.expect(t, error != "", reference)
	}
	content_test_game(t, root)
	content_test_write(t, root, "assets.json", `{"version":1,"assets":{},"dependencies":{"project.json":["missing-live.bin"]}}`)
	_, error := plan_content(root, {}, "game.exe")
	testing.expect(t, strings.contains(error, "missing-live.bin"), error)
}

@(test)
catalog_planning_requires_exact_catalog_filename_and_valid_metadata :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root := content_test_root(t)
	defer content_test_cleanup(root)
	content_test_game(t, root)
	_, error := plan_content(root, {}, "game.exe")
	testing.expect(t, strings.contains(error, "assets.json"), error)
	content_test_write(t, root, "ASSETS.json", CATALOG_TEST_EMPTY)
	_, error = plan_content(root, {}, "game.exe")
	testing.expect(t, strings.contains(error, "case"), error)
	wrong_case, _ := filepath.join({root, "ASSETS.json"})
	testing.expect(t, os.remove(wrong_case) == nil)
	for catalog in ([]string{
		`{"version":1,"assets":{},"unknown":true}`,
		`{"version":1,"assets":{},"version":1}`,
		`{"version":1,"assets":{},}`,
		`{"version":1,"assets":{}} trailing`,
		`[]`, `{"version":2,"assets":{}}`, `{"version":1.0,"assets":{}}`, `{"assets":{}}`, `{"version":1}`,
		`{"version":1,"assets":[],"directories":{}}`,
		`{"version":1,"assets":{},"$schema":{}}`,
		`{"version":1,"assets":{},"roots":["project.json"]}`,
		`{"version":1,"assets":{"../bad":"project.json"}}`,
		`{"version":1,"assets":{"bad\tname":"project.json"}}`,
		`{"version":1,"assets":{"same":"project.json"},"directories":{"same":"scenes/"}}`,
		`{"version":1,"assets":{},"dependencies":{"missing.json":[]}}`,
		`{"version":1,"assets":{},"dependencies":{"PROJECT.json":[]}}`,
		`{"version":1,"assets":{},"dependencies":{"scenes":[]}}`,
		`{"version":1,"assets":{},"dependencies":{"project.json":["C:/outside"]}}`,
		`{"version":1,"assets":{},"dependencies":{"project.json":["scenes","scenes/"]}}`,
		`{"version":1,"assets":{},"inputs":{"project.json":"bad-digest"}}`,
		`{"version":1,"assets":{},"inputs":[]}`,
	}) {
		content_test_write(t, root, "assets.json", catalog)
		_, error := plan_content(root, {}, "game.exe")
		testing.expect(t, error != "", catalog)
	}
}

@(test)
catalog_planning_checks_source_input_hashes_and_directory_inventory_changes :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root := content_test_root(t)
	defer content_test_cleanup(root)
	content_test_game(t, root)
	content_test_write(t, root, "src/z.odin", "package game\n")
	content_test_write(t, root, "src/nested/a.odin", "package game\nmain :: proc() {}\n")
	project_digest, error := catalog_input_digest(root, "project.json")
	testing.expect(t, error == "", error)
	source_digest: string
	source_digest, error = catalog_input_digest(root, "src/")
	testing.expect(t, error == "", error)
	expected_data := fmt.aprintf("nested/a.odin%c%s\nz.odin%c%s\n", u8(0), hash_bytes(transmute([]u8)string("package game\nmain :: proc() {}\n")), u8(0), hash_bytes(transmute([]u8)string("package game\n")))
	testing.expect(t, source_digest == hash_bytes(transmute([]u8)expected_data), "directory digest must follow the portable documented format")
	catalog, _ := strings.replace_all(`{"version":1,"assets":{},"inputs":{"project.json":"$PROJECT","src/":"$SOURCE"}}`, "$PROJECT", project_digest)
	catalog, _ = strings.replace_all(catalog, "$SOURCE", source_digest)
	content_test_write(t, root, "assets.json", catalog)
	plan, plan_error := plan_content(root, {}, "game.exe")
	testing.expect(t, plan_error == "", plan_error)
	testing.expect(t, !catalog_test_contains(plan.files, "src/z.odin") && !catalog_test_contains(plan.files, "src/nested/a.odin"))
	content_test_write(t, root, "src/new.odin", "package game\n")
	_, error = plan_content(root, {}, "game.exe")
	testing.expect(t, strings.contains(error, "regenerate") && strings.contains(error, "src/"), error)
	new_source, _ := filepath.join({root, "src/new.odin"})
	testing.expect(t, os.remove(new_source) == nil)
	content_test_write(t, root, "src/z.odin", "package changed\n")
	_, error = plan_content(root, {}, "game.exe")
	testing.expect(t, strings.contains(error, "regenerate"), error)
	_, error = catalog_input_digest(root, "SRC/")
	testing.expect(t, strings.contains(error, "case"), error)
}

@(test)
catalog_planning_rejects_linked_ancestors_and_catalog_files :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		arena: mem.Dynamic_Arena
		mem.dynamic_arena_init(&arena)
		defer mem.dynamic_arena_destroy(&arena)
		context.allocator = mem.dynamic_arena_allocator(&arena)
		root := content_test_root(t)
		defer content_test_cleanup(root)
		content_test_game(t, root)
		content_test_write(t, root, "metadata/real-assets.json", CATALOG_TEST_EMPTY)
		link, _ := filepath.join({root, "linked"})
		target, _ := filepath.join({root, "metadata"})
		testing.expect(t, os.symlink(target, link) == nil)
		catalog, _ := filepath.join({root, "assets.json"})
		catalog_target, _ := filepath.join({target, "real-assets.json"})
		testing.expect(t, os.symlink(catalog_target, catalog) == nil)
		_, error := plan_content(root, {}, "game.exe")
		testing.expect(t, strings.contains(error, "symbolic"), error)
		testing.expect(t, os.remove(catalog) == nil)
		content_test_write(t, root, "assets.json", `{"version":1,"assets":{"linked":"linked/real-assets.json"}}`)
		_, error = plan_content(root, {}, "game.exe")
		testing.expect(t, strings.contains(error, "symbolic"), error)
		_, error = catalog_input_digest(root, "linked/")
		testing.expect(t, strings.contains(error, "symbolic"), error)
	}
}

@(test)
catalog_planning_deduplicates_overlapping_assets_and_licenses :: proc(t: ^testing.T) {
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
	content_test_write(t, root, "assets.json", `{"version":1,"assets":{"notice":"assets/notices/OFL.txt","alias":"assets/notices/OFL.txt"},"directories":{"notices":"assets/notices"}}`)
	config := Config{licenses={"assets/notices/OFL.txt", "assets/notices/"}}
	plan, error := plan_content(root, config, "game.exe")
	testing.expect(t, error == "", error)
	testing.expect(t, len(plan.files) == 5, "asset-contained licenses must appear once")
	testing.expect(t, catalog_test_contains(plan.files, "assets/notices/OFL.txt") && catalog_test_contains(plan.files, "assets/notices/LICENSE.txt"))
	testing.expect(t, !catalog_test_contains(plan.files, "assets/unused.png"))
	config.licenses = {"ASSETS/notices/OFL.txt"}
	_, error = plan_content(root, config, "game.exe")
	testing.expect(t, error != "", "license overlap cannot bypass exact case")
}
