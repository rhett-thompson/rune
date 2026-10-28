package validation

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
project_runtime_settings_validate_ranges_shapes_and_unknown_fields :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "rune-project-settings-*", context.allocator)
	if !testing.expect(t, directory_error == nil) {return}
	defer delete(directory)
	defer os.remove(directory)
	path := fmt.tprintf("%s/project.json", directory)
	defer os.remove(path)
	cases := []struct {fields, diagnostic: string}{
		{``, ""},
		{`,"jobs":{}`, ""},
		{`,"jobs":{"worker_count":0}`, ""},
		{`,"jobs":{"worker_count":32,"queue_capacity":4096}`, ""},
		{`,"jobs":{"worker_count":2.0,"queue_capacity":1}`, ""},
		{`,"jobs":null`, "$.jobs"},
		{`,"jobs":{"worker_count":-1}`, "$.jobs.worker_count"},
		{`,"jobs":{"worker_count":33}`, "$.jobs.worker_count"},
		{`,"jobs":{"worker_count":2.5}`, "$.jobs.worker_count"},
		{`,"jobs":{"queue_capacity":0}`, "$.jobs.queue_capacity"},
		{`,"jobs":{"queue_capacity":4097}`, "$.jobs.queue_capacity"},
		{`,"jobs":{"queue_capacity":null}`, "$.jobs.queue_capacity"},
		{`,"jobs":{"threads":2}`, "$.jobs.threads"},
		{`,"physics_3d":{},"render_3d":{}`, ""},
		{`,"physics_3d":{"worker_count":1}`, ""},
		{`,"physics_3d":{"worker_count":32}`, ""},
		{`,"physics_3d":{"worker_count":2.0}`, ""},
		{`,"render_3d":{"shadows":{}}`, ""},
		{`,"render_3d":{"shadows":{"directional_resolution":2,"spot_resolution":8192,"omni_resolution":3072}}`, ""},
		{`,"render_3d":{"shadows":{"spot_resolution":2e0}}`, ""},
		{`,"custom_game_setting":42`, ""},
		{`,"physics_3d":null`, "$.physics_3d"},
		{`,"physics_3d":[]`, "$.physics_3d"},
		{`,"physics_3d":true`, "$.physics_3d"},
		{`,"physics_3d":{"worker_count":0}`, "$.physics_3d.worker_count"},
		{`,"physics_3d":{"worker_count":33}`, "$.physics_3d.worker_count"},
		{`,"physics_3d":{"worker_count":-1}`, "$.physics_3d.worker_count"},
		{`,"physics_3d":{"worker_count":1.5}`, "$.physics_3d.worker_count"},
		{`,"physics_3d":{"worker_count":1.00000001}`, "$.physics_3d.worker_count"},
		{`,"physics_3d":{"worker_count":1e100}`, "$.physics_3d.worker_count"},
		{`,"physics_3d":{"worker_count":"2"}`, "$.physics_3d.worker_count"},
		{`,"physics_3d":{"worker_count":true}`, "$.physics_3d.worker_count"},
		{`,"physics_3d":{"worker_count":null}`, "$.physics_3d.worker_count"},
		{`,"physics_3d":{"workerCount":2}`, "$.physics_3d.workerCount"},
		{`,"render_3d":null`, "$.render_3d"},
		{`,"render_3d":[]`, "$.render_3d"},
		{`,"render_3d":{"shadow":{}}`, "$.render_3d.shadow"},
		{`,"render_3d":{"shadows":null}`, "$.render_3d.shadows"},
		{`,"render_3d":{"shadows":[]}`, "$.render_3d.shadows"},
		{`,"render_3d":{"shadows":{"directional":4096}}`, "$.render_3d.shadows.directional"},
		{`,"render_3d":{"shadows":{"directional_resolution":1}}`, "$.render_3d.shadows.directional_resolution"},
		{`,"render_3d":{"shadows":{"spot_resolution":8193}}`, "$.render_3d.shadows.spot_resolution"},
		{`,"render_3d":{"shadows":{"omni_resolution":-2}}`, "$.render_3d.shadows.omni_resolution"},
		{`,"render_3d":{"shadows":{"spot_resolution":2048.000001}}`, "$.render_3d.shadows.spot_resolution"},
		{`,"render_3d":{"shadows":{"spot_resolution":true}}`, "$.render_3d.shadows.spot_resolution"},
		{`,"render_3d":{"shadows":{"spot_resolution":"2048"}}`, "$.render_3d.shadows.spot_resolution"},
		{`,"render_3d":{"shadows":{"spot_resolution":null}}`, "$.render_3d.shadows.spot_resolution"},
	}
	for sample in cases {
		document := fmt.tprint(`{"name":"Project settings validation","window":{}`, sample.fields, `}`)
		if !testing.expect(t, os.write_entire_file(path, document) == nil) {return}
		report := validate_project(path)
		defer destroy_report(&report)
		testing.expect(t, is_valid(&report) == (sample.diagnostic == ""), document)
		if sample.diagnostic != "" && testing.expect(t, len(report.diagnostics) == 1, document) {
			testing.expect_value(t, report.diagnostics[0].path, sample.diagnostic)
		}
	}
}
