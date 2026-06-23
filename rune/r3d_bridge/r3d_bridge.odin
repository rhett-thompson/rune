package r3d_bridge

// r3d is vendored in third_party/r3d. An Odin binding and native build step
// belong here once the engine begins its 3D rendering milestone.
is_available :: proc() -> bool {
	return false
}
