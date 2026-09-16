package r3d_bridge

import "core:fmt"
import "core:strings"
import "rune:assets"
import r3d "r3d:r3d"

Model_Animation_Source :: struct {
	model, path, clip: string,
	revision, version: u64,
}

// Register the first clip of a separate animation file under a unique name.
// Source and model must share joint names, rest pose, and units. Registration
// survives scene/model reloads; loaded tracks are shared by model instances.
register_model_animation_source :: proc(ctx: ^Context, model, clip, path: string) -> bool {
	if !ctx.initialized || model == "" || path == "" || clip == "" ||
	   len(clip) >= 32 || strings.index_byte(clip, 0) >= 0 {return false}
	for &source in ctx.animation_sources {
		if source.model != model || source.clip != clip {continue}
		if source.path == path {return true}
		ctx.animation_source_version += 1
		source.path = retain_path(ctx, path)
		source.version = ctx.animation_source_version
		source.revision = 0
		return true
	}
	ctx.animation_source_version += 1
	append(&ctx.animation_sources, Model_Animation_Source{
		model = retain_path(ctx, model), path = retain_path(ctx, path),
		clip = retain_path(ctx, clip), version = ctx.animation_source_version,
	})
	return true
}

animation_source_revision :: proc(ctx: ^Context, manager: ^assets.Asset_Manager, model: string) -> u64 {
	version: u64
	for &source in ctx.animation_sources {
		if source.model != model {continue}
		revision, _ := assets.model_revision(manager, source.path)
		if revision != source.revision {
			ctx.animation_source_version += 1
			source.version = ctx.animation_source_version
			source.revision = revision
		}
		version = max(version, source.version)
	}
	return version
}

import_animation_set :: proc(ctx: ^Context, manager: ^assets.Asset_Manager, path: string, model: r3d.Model) -> r3d.AnimationLib {
	library := import_model_animations(fmt.ctprintf("%s", resolve_path(ctx, path)))
	skeleton := model.skeleton
	for source in ctx.animation_sources {
		if source.model != path {continue}
		if !append_imported_animation(&library,
			fmt.ctprintf("%s", resolve_path(ctx, source.path)), &skeleton,
			fmt.ctprintf("%s", source.clip)) {
			r3d.UnloadAnimationLib(library)
			report_animation_failure(manager, source.path,
				fmt.tprintf("could not import clip '%s' for '%s': use a unique clip name and the same rig", source.clip, path))
			return {}
		}
		assets.resolve_asset_failure(manager, "", "ModelAnimator.clip", source.path)
	}
	return library
}
