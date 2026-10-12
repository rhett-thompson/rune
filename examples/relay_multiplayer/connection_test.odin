package main

import "core:net"
import "core:testing"
import "core:thread"
import "core:time"
import "rune:network"

connection_test_wait :: proc(job: ^Connection_Job) -> bool {
	started := time.tick_now()
	for time.tick_since(started) < 5*time.Second {
		if connection_ready(job) {return true}
		time.sleep(time.Millisecond)
	}
	return false
}

// Test jobs are stack storage, unlike the application's process-lifetime job.
// All test endpoints are local and bounded; ensure the worker cannot retain a
// pointer into a completed test, including a failing test's early return.
connection_test_cleanup :: proc(job: ^Connection_Job) {
	if !job.running {return}
	thread.join(job.worker)
	connection_shutdown(job)
}

@(test)
menu_connection_transfers_client_once_without_using_endpoint_storage :: proc(t: ^testing.T) {
	listener, listen_error := net.listen_tcp({net.IP4_Loopback, 0})
	if !testing.expect(t, listen_error == nil) {return}
	defer net.close(listener)
	endpoint, endpoint_error := net.bound_endpoint(listener)
	if !testing.expect(t, endpoint_error == nil) {return}
	job: Connection_Job
	defer connection_test_cleanup(&job)
	// The job owns its endpoint before the input field can change or disappear.
	endpoint_text := net.endpoint_to_string(endpoint)
	input: [256]u8
	copy(input[:], transmute([]u8)endpoint_text)
	if !testing.expect(t, connection_start(&job, string(input[:len(endpoint_text)]))) {return}
	input = {}
	testing.expect(t, !connection_start(&job, "127.0.0.1:1"), "only one dial may own the job at a time")
	if !testing.expect(t, connection_test_wait(&job)) {return}
	client: network.Client
	defer network.disconnect(&client)
	error, ready := connection_take(&job, &client)
	testing.expect(t, ready && error == nil)
	testing.expect(t, !job.running && job.worker == nil && !job.client.transport.open)
	testing.expect(t, client.status == .Connected && client.transport.open)
	_, again := connection_take(&job, &client)
	testing.expect(t, !again && client.transport.open, "taking twice must not close the transferred client")
	receiver, _, accept_error := net.accept_tcp(listener)
	if !testing.expect(t, accept_error == nil) {return}
	defer net.close(receiver)
	// The transferred socket is live and remains owned by the main thread.
	bytes := [1]u8{42}
	sent, send_error := net.send_tcp(client.transport.socket, bytes[:])
	if !testing.expect(t, send_error == nil && sent == 1) {return}
	read, receive_error := net.recv_tcp(receiver, bytes[:])
	testing.expect(t, receive_error == nil && read == 1 && bytes[0] == 42)
}

@(test)
menu_connection_reports_closed_port_and_can_retry :: proc(t: ^testing.T) {
	listener, listen_error := net.listen_tcp({net.IP4_Loopback, 0})
	if !testing.expect(t, listen_error == nil) {return}
	endpoint, endpoint_error := net.bound_endpoint(listener)
	net.close(listener)
	if !testing.expect(t, endpoint_error == nil) {return}
	job: Connection_Job
	defer connection_test_cleanup(&job)
	client: network.Client
	defer network.disconnect(&client)
	testing.expect(t, !connection_start(&job, ""))
	too_long: [256]u8
	testing.expect(t, !connection_start(&job, string(too_long[:])))
	for _ in 0..<2 {
		if !testing.expect(t, connection_start(&job, net.endpoint_to_string(endpoint))) {return}
		if !testing.expect(t, connection_test_wait(&job)) {return}
		error, ready := connection_take(&job, &client)
		testing.expect(t, ready && error != nil)
		testing.expect(t, !job.running && client.status == .Disconnected && !client.transport.open)
	}
}

@(test)
menu_connection_cancellation_closes_a_successful_dial :: proc(t: ^testing.T) {
	listener, listen_error := net.listen_tcp({net.IP4_Loopback, 0})
	if !testing.expect(t, listen_error == nil) {return}
	defer net.close(listener)
	endpoint, endpoint_error := net.bound_endpoint(listener)
	if !testing.expect(t, endpoint_error == nil) {return}
	job: Connection_Job
	defer connection_test_cleanup(&job)
	if !testing.expect(t, connection_start(&job, net.endpoint_to_string(endpoint))) {return}
	connection_cancel(&job)
	testing.expect(t, job.running && job.cancelled)
	if !testing.expect(t, connection_test_wait(&job)) {return}
	testing.expect(t, job.client.transport.open, "successful dial is held until the cancelled result is collected")
	client: network.Client
	error, ready := connection_take(&job, &client)
	testing.expect(t, ready && error == nil && !job.running && !client.transport.open)
	receiver, _, accept_error := net.accept_tcp(listener)
	if !testing.expect(t, accept_error == nil) {return}
	defer net.close(receiver)
	testing.expect(t, net.set_blocking(receiver, false) == nil)
	bytes: [1]u8
	closed := false
	started := time.tick_now()
	for time.tick_since(started) < 5*time.Second {
		read, receive_error := net.recv_tcp(receiver, bytes[:])
		if receive_error == nil && read == 0 {closed = true; break}
		if receive_error != nil && receive_error != .Would_Block && receive_error != .Interrupted {break}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, closed, "discarding a cancelled result must close its socket")
	// A cancelled job can be reused after its result has been discarded.
	if !testing.expect(t, connection_start(&job, net.endpoint_to_string(endpoint))) {return}
	if !testing.expect(t, connection_test_wait(&job)) {return}
	connection_shutdown(&job)
	testing.expect(t, !job.running && !job.client.transport.open)
}
