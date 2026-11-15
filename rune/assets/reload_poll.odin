package assets

import "base:runtime"
import "core:mem"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "rune:jobs"
import "rune:pathutil"

Asset_Reload_Kind :: enum {Textures, Models, Terrains, Navmeshes, Materials, Animations, Tilesets, Shadow_Profiles}
Asset_Reload_Kinds :: bit_set[Asset_Reload_Kind]

Asset_Reload_Sample :: struct {
	stamp: i64,
	rechecked: bool,
}

Asset_Reload_Poll :: struct {
	kinds: Asset_Reload_Kinds,
	paths: [dynamic]string,
	samples: map[string]Asset_Reload_Sample,
	next: int,
	applying: bool,
	probe: ^Asset_Reload_Probe,
}

@(private)
Asset_Reload_Probe :: struct {
	group: jobs.Group,
	arena: mem.Dynamic_Arena,
	files: []struct {path: string, stamp: i64},
}

// Sample an owned snapshot on the configured pool or spread a serial sweep
// across frames. The owner still applies reloads and validates changed stamps.
advance_reload_poll :: proc(manager: ^Asset_Manager, kinds: Asset_Reload_Kinds, due: bool) {
	if manager == nil {return}
	poll := &manager.reload_poll
	if poll.kinds != {} && poll.kinds != kinds {clear_reload_poll(poll)}
	if !finish_reload_probe(poll) {return}
	if kinds == {} {return}
	if poll.kinds == {} {
		if !due {return}
		begin_reload_poll(manager, kinds)
	}
	if state := manager.texture_reloads; state != nil && poll.next == 0 && len(poll.paths) > 0 {
		if start_reload_probe(manager, state.pool) {return}
	}
	if !sample_reload_paths(manager, 2*time.Millisecond) {return}
	poll.applying = true
	defer clear_reload_poll(poll)
	if .Shadow_Profiles in kinds {refresh_shadow_profiles(manager)}
	if .Textures in kinds {refresh_background(manager)}
	if .Models in kinds {
		refresh_models(manager)
		refresh_skyboxes(manager)
	}
	if .Terrains in kinds {refresh_terrains(manager)}
	if .Navmeshes in kinds {refresh_navmeshes(manager)}
	if .Materials in kinds {refresh_materials(manager)}
	if .Animations in kinds {refresh_animations(manager)}
	if .Tilesets in kinds {refresh_tilesets(manager)}
}

@(private)
start_reload_probe :: proc(manager: ^Asset_Manager, pool: ^jobs.Pool) -> bool {
	allocator := runtime.default_context().allocator
	probe, alloc_error := mem.new(Asset_Reload_Probe, allocator)
	if alloc_error != nil {return false}
	mem.dynamic_arena_init(&probe.arena, block_allocator=allocator, array_allocator=allocator)
	accepted := false
	defer if !accepted {free_reload_probe(probe)}
	storage := mem.dynamic_arena_allocator(&probe.arena)
	poll := &manager.reload_poll
	probe.files, alloc_error = make(type_of(probe.files), len(poll.paths), storage)
	if alloc_error != nil {return false}
	for path, index in poll.paths {
		resolved := resolve_path(manager, path)
		if resolved == "" {continue}
		if filepath.is_abs(resolved) {
			probe.files[index].path, alloc_error = strings.clone(resolved, storage)
			if alloc_error != nil {return false}
		} else {
			absolute, err := pathutil.absolute(resolved, storage)
			if err != nil {return false}
			probe.files[index].path = absolute
		}
	}
	accepted = jobs.submit(pool, &probe.group, sample_reload_probe, probe)
	if !accepted {return false}
	poll.probe = probe
	return true
}

@(private)
sample_reload_probe :: proc(data: rawptr) {
	probe := (^Asset_Reload_Probe)(data)
	for &file in probe.files {file.stamp = modified_time(file.path)}
}

@(private)
finish_reload_probe :: proc(poll: ^Asset_Reload_Poll) -> bool {
	probe := poll.probe
	if probe == nil {return true}
	if !jobs.is_complete(&probe.group) {return false}
	if poll.kinds != {} {
		for file, index in probe.files {poll.samples[poll.paths[index]] = {stamp=file.stamp}}
		poll.next = len(poll.paths)
	}
	free_reload_probe(probe)
	poll.probe = nil
	return true
}

@(private)
free_reload_probe :: proc(probe: ^Asset_Reload_Probe) {
	mem.dynamic_arena_destroy(&probe.arena)
	free(probe, runtime.default_context().allocator)
}

@(private)
drain_reload_poll :: proc(poll: ^Asset_Reload_Poll) {
	clear_reload_poll(poll)
	if probe := poll.probe; probe != nil {
		jobs.wait(&probe.group)
		free_reload_probe(probe)
		poll.probe = nil
	}
}

@(private)
begin_reload_poll :: proc(manager: ^Asset_Manager, kinds: Asset_Reload_Kinds) {
	poll := &manager.reload_poll
	poll.kinds = kinds
	if poll.samples == nil {
		allocator := runtime.default_context().allocator
		poll.paths = make([dynamic]string, allocator=allocator)
		poll.samples = make(map[string]Asset_Reload_Sample, allocator=allocator)
	}
	if .Shadow_Profiles in kinds {
		for path in manager.shadow_profiles {include_reload_path(poll, path)}
	}
	if .Textures in kinds {
		for path in manager.textures {include_reload_path(poll, path)}
		for path in manager.missing_textures {include_reload_path(poll, path)}
		for key in manager.fonts {include_reload_path(poll, key.path)}
	}
	if .Models in kinds {
		for path in manager.models {include_reload_path(poll, path)}
		for path in manager.skyboxes {include_reload_path(poll, path)}
	}
	if .Terrains in kinds {
		for path, asset in manager.terrains {
			include_reload_path(poll, path)
			if asset.watched_heightmap != "" {include_reload_path(poll, asset.watched_heightmap)}
		}
	}
	if .Navmeshes in kinds {
		for path in manager.navmeshes {include_reload_path(poll, path)}
	}
	if .Materials in kinds {
		for _, asset in manager.model_materials {include_reload_path(poll, asset.sidecar_path)}
		for path in manager.materials {include_reload_path(poll, path)}
		for path in manager.material_texture_watches {include_reload_path(poll, path)}
	}
	if .Animations in kinds {
		for path in manager.model_events {include_reload_path(poll, path)}
		for path in manager.animations {include_reload_path(poll, path)}
	}
	if .Tilesets in kinds {
		for path in manager.tilesets {include_reload_path(poll, path)}
	}
}

@(private)
include_reload_path :: proc(poll: ^Asset_Reload_Poll, path: string) {
	if _, included := poll.samples[path]; included {return}
	// Asset keys borrow the manager's retained paths for its lifetime.
	poll.samples[path] = {}
	append(&poll.paths, path)
}

@(private)
sample_reload_paths :: proc(manager: ^Asset_Manager, budget: time.Duration) -> bool {
	poll := &manager.reload_poll
	start := time.tick_now()
	for poll.next < len(poll.paths) {
		path := poll.paths[poll.next]
		poll.samples[path] = {stamp=modified_time(resolve_path(manager, path))}
		poll.next += 1
		if time.tick_since(start) >= budget {break}
	}
	return poll.next == len(poll.paths)
}

@(private)
reload_stamp :: proc(manager: ^Asset_Manager, path: string, previous: i64) -> i64 {
	poll := &manager.reload_poll
	if !poll.applying {return modified_time(resolve_path(manager, path))}
	sample, found := poll.samples[path]
	if !found {
		// The asset was first watched after this scan began. Check it next time.
		return previous
	}
	if sample.stamp != previous && !sample.rechecked {
		// An upload or a direct refresh can commit a newer stamp mid-sweep.
		// Confirm suspected changes before reloading or updating any watch.
		sample = {stamp=modified_time(resolve_path(manager, path)), rechecked=true}
		poll.samples[path] = sample
	}
	return sample.stamp
}

@(private)
clear_reload_poll :: proc(poll: ^Asset_Reload_Poll) {
	clear(&poll.paths)
	clear(&poll.samples)
	poll.kinds = {}
	poll.next = 0
	poll.applying = false
}
