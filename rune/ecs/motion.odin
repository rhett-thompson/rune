package ecs

import "core:encoding/json"
import "core:math"

// Orbit moves an entity's local position around its parent on the XZ plane.
// Its initial Transform position supplies the orbital radius and starting angle.
Orbit :: struct {
	degrees_per_second: f32,
}

// Rotator spins an entity around its local Y axis.
Rotator :: struct {
	degrees_per_second: f32,
}

orbit_from_json :: proc(data: json.Value) -> (Orbit, bool) {
	object, ok := data.(json.Object)
	if !ok {return {}, false}
	value, found := object["degrees_per_second"]
	if !found {return {}, false}
	degrees_per_second, number_ok := read_number(value)
	if !number_ok {return {}, false}
	return Orbit{degrees_per_second = degrees_per_second}, true
}

rotator_from_json :: proc(data: json.Value) -> (Rotator, bool) {
	object, ok := data.(json.Object)
	if !ok {return {}, false}
	value, found := object["degrees_per_second"]
	if !found {return {}, false}
	degrees_per_second, number_ok := read_number(value)
	if !number_ok {return {}, false}
	return Rotator{degrees_per_second = degrees_per_second}, true
}

// update_orbits advances every Orbit using its local position as its radius.
// Parent transforms are applied by the renderer, so this naturally supports
// nested orbits such as a moon around an orbiting planet.
update_orbits :: proc(world: ^World, dt: f32) {
	for entity, orbit in world.orbits {
		transform, has_transform := get_transform(world, entity)
		if !has_transform {continue}

		angle := orbit.degrees_per_second * dt * f32(math.PI / 180.0)
		cosine := f32(math.cos(f64(angle)))
		sine := f32(math.sin(f64(angle)))
		x := transform.position[0]
		z := transform.position[2]
		transform.position[0] = x * cosine - z * sine
		transform.position[2] = x * sine + z * cosine
		set_transform(world, entity, transform)
	}
}

// update_rotators advances every Rotator around its local Y axis.
update_rotators :: proc(world: ^World, dt: f32) {
	for entity, rotator in world.rotators {
		transform, has_transform := get_transform(world, entity)
		if !has_transform {continue}
		transform.rotation[1] += rotator.degrees_per_second * dt
		set_transform(world, entity, transform)
	}
}
