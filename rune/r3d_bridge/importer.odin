package r3d_bridge

import r3d "r3d:r3d"

// The pinned R3D importer drops FBX animation channels attached to pivot
// helper nodes. This native build folds those pivots into the actual joints
// for both model and animation imports. See third_party/r3d-importer/README.md.
when ODIN_ARCH == .amd64 && (ODIN_OS == .Windows || ODIN_OS == .Linux) {
	when ODIN_OS == .Windows {
		foreign import importer_lib "../../third_party/r3d-importer/windows/importer.lib"
	} else {
		foreign import importer_lib "../../third_party/r3d-importer/linux/libimporter.a"
	}

	@(default_calling_convention="c")
	foreign importer_lib {
		@(link_name="Rune_LoadImporter")
		load_importer :: proc(path: cstring, flags: r3d.ImportFlags) -> ^r3d.Importer ---
		@(link_name="Rune_LoadImporterFromMemory")
		load_importer_from_memory :: proc(data: rawptr, size: u32, hint: cstring, flags: r3d.ImportFlags) -> ^r3d.Importer ---
		@(link_name="Rune_UnloadImporter")
		unload_importer :: proc(importer: ^r3d.Importer) ---
		@(link_name="Rune_AppendAnimation")
		append_imported_animation :: proc(library: ^r3d.AnimationLib, path: cstring, skeleton: ^r3d.Skeleton, name: cstring) -> bool ---
	}
} else {
	load_importer :: r3d.LoadImporter
	load_importer_from_memory :: r3d.LoadImporterFromMemory
	unload_importer :: r3d.UnloadImporter
	append_imported_animation :: proc(library: ^r3d.AnimationLib, path: cstring, skeleton: ^r3d.Skeleton, name: cstring) -> bool {return false}
}

import_model :: proc(path: cstring) -> r3d.Model {
	importer := load_importer(path, {})
	if importer == nil {return {}}
	defer unload_importer(importer)
	return r3d.LoadModelFromImporter(importer)
}

import_model_animations :: proc(path: cstring) -> r3d.AnimationLib {
	importer := load_importer(path, {})
	if importer == nil {return {}}
	defer unload_importer(importer)
	return r3d.LoadAnimationLibFromImporter(importer)
}
