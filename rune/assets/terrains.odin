package assets

import "core:fmt"
import "rune:terrain"

Terrain_Asset :: struct {
	data: terrain.Data,
	revision: u64,
	descriptor_stamp, heightmap_stamp: i64,
	watched_heightmap: string, // retained by manager
}

terrain_data :: proc(manager: ^Asset_Manager, path: string) -> (terrain.Data,u64,bool) {
	if manager == nil || path == "" {return {},0,false}
	if _,found := manager.terrains[path]; !found {
		manager.terrains[retain_path(manager,path)] = {}
		load_terrain(manager,path,.Load)
	}
	asset := manager.terrains[path]
	return asset.data,asset.revision,asset.revision != 0
}

load_terrain :: proc(manager: ^Asset_Manager, path: string, operation: Asset_Operation) {
	old := manager.terrains[path]
	data,watch,error := terrain.load(manager.root,path)
	if old.watched_heightmap != watch {
		resolve_failure(&manager.diagnostics,path,"heightmap",old.watched_heightmap)
	}
	old.descriptor_stamp = modified_time(resolve_path(manager,path))
	old.watched_heightmap = retain_path(manager,watch)
	old.heightmap_stamp = modified_time(resolve_path(manager,watch))
	if error != "" {
		report_failure(manager,{kind=.Terrain,operation=operation,source_path=path,field="heightmap",asset_path=watch,
			detail=fmt.tprint(error,"; keeping the last working terrain, or omitting terrain if none loaded")})
	} else {
		terrain.destroy(&old.data)
		old.data = data
		old.revision += 1
		resolve_failure(&manager.diagnostics,path,"heightmap",watch)
	}
	manager.terrains[path] = old
}

refresh_terrains :: proc(manager: ^Asset_Manager) {
	for path,asset in manager.terrains {
		if modified_time(resolve_path(manager,path)) != asset.descriptor_stamp ||
		   (asset.watched_heightmap != "" && modified_time(resolve_path(manager,asset.watched_heightmap)) != asset.heightmap_stamp) {
			load_terrain(manager,path,.Reload)
		}
	}
}

shutdown_terrains :: proc(manager: ^Asset_Manager) {
	for _, &asset in manager.terrains {terrain.destroy(&asset.data)}
	delete(manager.terrains)
	manager.terrains = nil
}
