package assets

// Asset paths are the first asset identifiers. Stable IDs can be layered on later.
Asset_Manager :: struct {
	root: string,
}

init :: proc(root: string) -> Asset_Manager {
	return Asset_Manager{root = root}
}
