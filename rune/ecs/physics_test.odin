package ecs

import "core:sync"

// Box3D's native world pool selects an unused slot before marking it in use;
// CreateWorld/DestroyWorld cannot run concurrently. The threaded test runner
// otherwise lets independent fixtures claim the same native slot. Keep native
// world fixtures serialized for their complete lifetime, including teardown.
@(private)
native_physics_test_mutex: sync.Mutex

@(private)
lock_native_physics_test :: proc() {sync.mutex_lock(&native_physics_test_mutex)}

@(private)
unlock_native_physics_test :: proc() {sync.mutex_unlock(&native_physics_test_mutex)}
