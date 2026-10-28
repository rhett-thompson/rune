package main

import "core:fmt"
import "core:os"
import "core:time"
import rune "rune:core"
import "rune:jobs"
import rl "vendor:raylib"

increment :: proc(data: rawptr) {
	// Keep an accepted callback pending as the owner enters shutdown.
	time.sleep(20*time.Millisecond)
	(^int)(data)^ += 1
}

validate_runtime :: proc(path: string) {
	assert(os.write_entire_file(path,`{"name":"Jobs runtime","window":{"width":64,"height":64,"hidden":true},"jobs":{"worker_count":2,"queue_capacity":1}}`)==nil)
	game,initialized:=rune.init(path)
	assert(initialized && game.is_running && game.worker_pool!=nil,"engine creates its configured pool")
	assert(game.window.hidden && rl.IsWindowState({.WINDOW_HIDDEN}),"runtime fixture stays hidden")
	writes:int
	group:jobs.Group
	assert(jobs.submit(game.worker_pool,&group,increment,&writes))
	rune.shutdown(&game)
	assert(writes==1 && jobs.is_complete(&group) && game.worker_pool==nil && !game.is_running,
		"shutdown drains accepted callbacks and releases the engine-owned pool")
	assert(os.write_entire_file(path,`{"name":"Jobs disabled","window":{"width":64,"height":64,"hidden":true}}`)==nil)
	game,initialized=rune.init(path)
	assert(initialized && game.is_running && game.worker_pool==nil,"engine reinitialization retains the default disabled pool")
	assert(game.window.hidden && rl.IsWindowState({.WINDOW_HIDDEN}),"reinitialized fixture stays hidden")
	rune.shutdown(&game)
	assert(!game.is_running && game.worker_pool==nil)
	fmt.println("Jobs runtime validation passed: configured startup, callback drain, shutdown ownership, and disabled-pool reinitialization")
}

main :: proc() {
	runtime:=false
	for argument in os.args[1:] {
		if argument!="--runtime" {fmt.eprintln("Usage: jobs_validation [--runtime]");os.exit(2)}
		runtime=true
	}
	directory,error:=os.make_directory_temp("build","engine-jobs-validation-*",context.allocator)
	assert(error==nil);defer delete(directory);defer os.remove(directory)
	path:=fmt.aprintf("%s/project.json",directory)
	defer delete(path);defer os.remove(path)
	assert(os.write_entire_file(path,`{"name":"Jobs settings","window":{},"jobs":{"worker_count":2,"queue_capacity":1}}`)==nil)
	project,loaded:=rune.load_project(path)
	assert(loaded && project.jobs.worker_count==2 && project.jobs.queue_capacity==1)
	rune.destroy_project(&project)
	fmt.println("Jobs project settings validation passed")
	if runtime {validate_runtime(path)}
	else {fmt.println("Skipped engine startup/shutdown runtime checks; pass --runtime with a working display")}
}
