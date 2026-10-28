package core

import "rune:scene"
import "rune:jobs"

Jobs_Settings :: struct {
	// Additional background threads, independent of Box3D's native workers.
	worker_count: int,
	queue_capacity: int,
}

jobs_settings_valid :: proc(settings: Jobs_Settings) -> bool {
	return settings.worker_count >= 0 && settings.worker_count <= jobs.Max_Workers &&
		settings.queue_capacity >= 1 && settings.queue_capacity <= jobs.Max_Queue_Capacity
}

Physics_3D_Settings :: struct {
	// Includes the calling thread. Applied when each native world is created.
	worker_count: int,
}

project_scene_options :: proc(engine: ^Engine) -> scene.Load_Options {
	// A manually constructed Engine has no decoded project defaults. Scene
	// loading treats its zero-valued option as the ordinary single worker.
	return {physics_3d_worker_count = engine.project.physics_3d.worker_count}
}
