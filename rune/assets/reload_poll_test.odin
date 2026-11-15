package assets

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "rune:jobs"

@(test)
reload_poll_shares_stamps_and_watches_new_sidecars :: proc(t: ^testing.T) {
	file, err := os.create_temp_file("", "rune-reload-poll-*.obj")
	if !testing.expect(t, err == nil) {return}
	model, _ := strings.clone(os.name(file))
	defer delete(model)
	testing.expect(t, os.close(file) == nil)
	defer os.remove(model)
	sidecar := fmt.aprintf("%s.materials.json", model)
	defer delete(sidecar)
	defer os.remove(sidecar)
	manager := material_preview_test_manager()
	defer shutdown(&manager)
	manager.models = make(map[string]Model_Asset)
	manager.models[retain_path(&manager, model)] = {modified_time = -1, revision = 1}
	manager.material_texture_watches[retain_path(&manager, model)] = -1
	testing.expect(t, len(model_material_paths(&manager, model)) == 0)
	testing.expect(t, os.write_entire_file(sidecar, `{"materials":{"0":"materials/new.json"}}`) == nil)

	kinds := Asset_Reload_Kinds{.Models, .Materials}
	begin_reload_poll(&manager, kinds)
	testing.expect(t, len(manager.reload_poll.paths) == 2, "the shared file and optional sidecar each get one probe")
	testing.expect(t, !sample_reload_paths(&manager, 0) && manager.reload_poll.next == 1)
	testing.expect(t, manager.models[model].revision == 1 && model_material_path(&manager, model, 0) == "",
		"partial scanning leaves the current cache visible")
	for _ in 0..<2 {advance_reload_poll(&manager, kinds, false)}
	stamp := manager.models[model].modified_time
	testing.expect(t, stamp >= 0 && manager.models[model].revision == 2 && manager.material_texture_watches[model] == stamp)
	testing.expect(t, model_material_path(&manager, model, 0) == "materials/new.json")
	testing.expect(t, manager.reload_poll.kinds == {} && len(manager.reload_poll.samples) == 0)
}

@(test)
reload_poll_discards_pending_samples_when_disabled :: proc(t: ^testing.T) {
	manager := material_preview_test_manager()
	defer shutdown(&manager)
	manager.models = make(map[string]Model_Asset)
	manager.models["missing-model.obj"] = {modified_time = -2, revision = 1}
	begin_reload_poll(&manager, {.Models})
	testing.expect(t, sample_reload_paths(&manager, 0))
	advance_reload_poll(&manager, {}, false)
	testing.expect(t, manager.reload_poll.kinds == {} && manager.reload_poll.next == 0 && manager.models["missing-model.obj"].revision == 1)
	refresh_models(&manager)
	testing.expect(t, manager.models["missing-model.obj"].revision == 2, "an explicit refresh still probes immediately")
}

@(test)
reload_poll_keeps_a_stamp_committed_after_sampling :: proc(t: ^testing.T) {
	file, err := os.create_temp_file("", "rune-reload-poll-*.obj")
	if !testing.expect(t, err == nil) {return}
	path, _ := strings.clone(os.name(file))
	defer delete(path)
	assert(os.close(file) == nil)
	assert(os.remove(path) == nil)
	defer os.remove(path)
	manager := material_preview_test_manager()
	defer shutdown(&manager)
	manager.models = make(map[string]Model_Asset)
	manager.models[retain_path(&manager, path)] = {modified_time = -1, revision = 1}
	begin_reload_poll(&manager, {.Models})
	assert(sample_reload_paths(&manager, 0))
	testing.expect(t, manager.reload_poll.samples[path].stamp == -1)

	assert(os.write_entire_file(path, "new asset") == nil)
	refresh_models(&manager)
	committed := manager.models[path]
	testing.expect(t, committed.modified_time >= 0 && committed.revision == 2)
	advance_reload_poll(&manager, {.Models}, false)
	testing.expect(t, manager.models[path].modified_time == committed.modified_time &&
		manager.models[path].revision == committed.revision, "an old sample cannot overwrite a newer stamp")
}

@(private="file")
Reload_Poll_Test_Gate :: struct {started, release: sync.Sema}

@(private="file")
reload_poll_test_gate_worker :: proc(data: rawptr) {
	gate := (^Reload_Poll_Test_Gate)(data)
	sync.sema_post(&gate.started)
	sync.sema_wait(&gate.release)
}

@(test)
reload_poll_samples_on_a_worker_and_discards_disabled_results :: proc(t: ^testing.T) {
	file, err := os.create_temp_file("", "rune-background-poll-*.obj")
	if !testing.expect(t, err == nil) {return}
	path := strings.clone(os.name(file))
	defer delete(path)
	assert(os.close(file) == nil)
	defer os.remove(path)
	pool := jobs.create(1, 1)
	if !testing.expect(t, pool != nil) {return}
	defer jobs.destroy(pool)
	manager := material_preview_test_manager()
	defer shutdown(&manager)
	manager.models = make(map[string]Model_Asset)
	manager.models[retain_path(&manager, path)] = {modified_time = -1, revision = 1}
	assert(configure_asset_jobs(&manager, pool))

	gate: Reload_Poll_Test_Gate
	blocker: jobs.Group
	assert(jobs.submit(pool, &blocker, reload_poll_test_gate_worker, &gate))
	released := false
	defer {
		if !released {sync.sema_post(&gate.release)}
		jobs.wait(&blocker)
	}
	sync.sema_wait(&gate.started)
	kinds := Asset_Reload_Kinds{.Models}
	advance_reload_poll(&manager, kinds, true)
	probe := manager.reload_poll.probe
	if !testing.expect(t, probe != nil) {return}
	testing.expect(t, manager.models[path].revision == 1, "queued sampling must leave the cache untouched")
	advance_reload_poll(&manager, {}, false)
	testing.expect(t, manager.reload_poll.kinds == {} && manager.reload_poll.probe == probe)
	sync.sema_post(&gate.release)
	released = true
	jobs.wait(&probe.group)
	advance_reload_poll(&manager, {}, false)
	testing.expect(t, manager.reload_poll.probe == nil && manager.models[path].revision == 1)

	advance_reload_poll(&manager, kinds, true)
	probe = manager.reload_poll.probe
	if !testing.expect(t, probe != nil) {return}
	jobs.wait(&probe.group)
	testing.expect(t, manager.models[path].revision == 1, "the worker only samples timestamps")
	advance_reload_poll(&manager, kinds, false)
	testing.expect(t, manager.models[path].revision == 2 && manager.reload_poll.probe == nil)

	advance_reload_poll(&manager, kinds, true)
	assert(configure_asset_jobs(&manager, nil))
	testing.expect(t, manager.reload_poll.probe == nil && manager.reload_poll.kinds == {})
}
