package main

import "base:runtime"
import "core:mem"
import "core:net"
import "core:sync"
import "core:thread"
import "rune:network"

// Keep this job at a stable address for the process lifetime, such as a global.
// DNS and TCP dialing can outlive a cancelled menu action or engine shutdown.
// The worker only writes its result here; it never touches game or UI state.
Connection_Job :: struct {
	worker: ^thread.Thread,
	client: network.Client,
	server: [256]u8,
	server_length: int,
	error: net.Network_Error,
	completed: bool,
	running, cancelled: bool,
	use_udp: bool,
}

connection_worker :: proc(worker: ^thread.Thread) {
	job := (^Connection_Job)(worker.data)
	// Use thread-owned temporary storage: the engine resets its frame arena
	// while this synchronous dial may still be resolving or connecting.
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	previous_temp := context.temp_allocator
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	job.error = network.connect(&job.client, string(job.server[:job.server_length]), use_udp=job.use_udp)
	context.temp_allocator = previous_temp
	mem.dynamic_arena_destroy(&scratch)
	// Publish the client and error only after all worker writes have finished.
	sync.atomic_store_explicit(&job.completed, true, .Release)
}

connection_start :: proc(job: ^Connection_Job, server: string, use_udp: bool = false) -> bool {
	if job == nil || job.running || len(server) == 0 || len(server) >= len(job.server) {return false}
	job^ = {}
	copy(job.server[:], transmute([]u8)server)
	job.server_length = len(server)
	job.use_udp = use_udp
	// Thread metadata must survive engine arenas and their shutdown. A worker
	// gets its own default context; do not inherit the main frame allocator.
	previous_allocator := context.allocator
	context.allocator = runtime.default_context().allocator
	job.worker = thread.create(connection_worker, name = "relay connection")
	context.allocator = previous_allocator
	if job.worker == nil {return false}
	job.worker.data = job
	job.running = true
	thread.start(job.worker)
	return true
}

connection_ready :: proc(job: ^Connection_Job) -> bool {
	if job == nil || !job.running {return false}
	return sync.atomic_load_explicit(&job.completed, .Acquire) && thread.is_done(job.worker)
}

// Transfers socket ownership to client once. Cancelled results and calls with
// no output client close the socket instead. No DNS or TCP wait occurs here.
connection_take :: proc(job: ^Connection_Job, client: ^network.Client) -> (error: net.Network_Error, ready: bool) {
	if !connection_ready(job) {return nil, false}
	error = job.error
	thread.destroy(job.worker)
	if job.cancelled || client == nil {
		network.disconnect(&job.client)
	} else {
		network.disconnect(client)
		client^ = job.client
	}
	job^ = {}
	return error, true
}

connection_cancel :: proc(job: ^Connection_Job) {
	if job != nil && job.running {job.cancelled = true}
}

// Cancellation cannot interrupt core:net's synchronous DNS/TCP dial. On exit,
// do not join an unfinished worker: global job storage remains valid until
// process termination, which releases its thread handle and any open socket.
connection_shutdown :: proc(job: ^Connection_Job) {
	connection_cancel(job)
	connection_take(job, nil)
}
