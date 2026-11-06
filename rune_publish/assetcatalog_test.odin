package main

import "core:mem"
import "core:testing"

@(test)
pruning_uses_explicit_assetcatalog_values_and_existing_dependency_traversal :: proc(t:^testing.T) {
	arena:mem.Dynamic_Arena;mem.dynamic_arena_init(&arena);defer mem.dynamic_arena_destroy(&arena)
	context.allocator=mem.dynamic_arena_allocator(&arena)
	root:=content_test_root(t);defer content_test_cleanup(root)
	content_test_game(t,root)
	content_test_write(t,root,"assets.json",`{"$schema":"schemas/assetcatalog.schema.json","version":1,"assets":{"scene.extra":"scenes/extra.scene.json","data.level":"data/level.json"},"directories":{"dir.audio":"assets/audio"},"dependencies":{"data/level.json":["data/patrol.navmesh.json"]}}`)
	content_test_write(t,root,"scenes/extra.scene.json",`{"entities":[{"prefab":"../prefabs/extra.prefab.json"}]}`)
	content_test_write(t,root,"prefabs/extra.prefab.json",`{"components":{"SpriteRenderer":{"texture":"assets/extra.png"}}}`)
	content_test_write(t,root,"assets/extra.png","scene dependency")
	content_test_write(t,root,"assets/audio/wind.wav","named directory child")
	content_test_write(t,root,"assets/unused.png","unused")
	content_test_write(t,root,"data/level.json","custom level")
	content_test_write(t,root,"data/patrol.navmesh.json","custom dependency")
	content_test_write(t,root,"data/unused.bin","unused")
	config:=Config{content={"project.json","assets.json","scenes/","prefabs/","assets/","data/"},prune={enabled=true,manifests={"assets.json"}}}
	files:=pruning_test_files(t,root,config)
	retained,report,error:=prune_content(root,config,files)
	if !testing.expect(t,error=="",error) {return}
	for path in ([]string{"assets.json","scenes/main.scene.json","scenes/extra.scene.json","prefabs/extra.prefab.json","assets/extra.png","assets/audio/wind.wav","data/level.json","data/patrol.navmesh.json"}) {
		testing.expect(t,pruning_test_contains(retained,path),path)
	}
	testing.expect(t,!pruning_test_contains(retained,"assets/unused.png") && !pruning_test_contains(retained,"data/unused.bin"))
	testing.expect(t,len(report.manifests)==1 && report.manifests[0].path=="assets.json")
}
