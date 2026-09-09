package assets

// Track even missing files so creating or repairing them triggers a retry.
// GPU ownership belongs to r3d_bridge, keeping this package renderer-independent.
Skybox_Asset :: struct {
	modified_time: i64,
	revision: u64,
}

skybox_revision :: proc(manager: ^Asset_Manager, path: string) -> u64 {
	if manager == nil || path == "" {return 0}
	if asset, found := manager.skyboxes[path]; found {return asset.revision}
	manager.skyboxes[retain_path(manager, path)] = {modified_time = modified_time(resolve_path(manager, path)), revision = 1}
	return 1
}

refresh_skyboxes :: proc(manager: ^Asset_Manager) {
	for path, asset in manager.skyboxes {
		stamp := modified_time(resolve_path(manager, path))
		if stamp == asset.modified_time {continue}
		updated := asset
		updated.modified_time = stamp
		updated.revision += 1
		if updated.revision == 0 {updated.revision = 1}
		manager.skyboxes[path] = updated
	}
}
