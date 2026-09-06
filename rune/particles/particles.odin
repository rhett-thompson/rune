// CPU particles independent of the ECS and graphics context. Settings are
// declarative; State owns transient storage and must not be copied by callers.
package particles

import "core:math"

Emitter2D :: struct {
	max_particles: i32,
	emitting:      bool,
	rate:          f32,
	lifetime:      [2]f32,
	speed:         [2]f32,
	angle:         f32,
	spread:        f32,
	gravity:       [2]f32,
	start_size:    f32,
	end_size:      f32,
	start_color:   [4]u8,
	end_color:     [4]u8,
	texture:       string,
	additive:      bool,
	draw_order:    i32,
	seed:          u32,
}

defaults :: proc() -> Emitter2D {
	return {
		max_particles = 256, emitting = true, rate = 30,
		lifetime = {0.5, 1}, speed = {40, 100}, angle = -90, spread = 30,
		start_size = 8, end_size = 0,
		start_color = {255, 220, 120, 255}, end_color = {255, 80, 30, 0}, seed = 1,
	}
}

valid :: proc(value: Emitter2D) -> bool {
	if value.max_particles < 1 || value.max_particles > 65536 ||
	   value.rate < 0 || value.rate > 100000 ||
	   value.lifetime[0] <= 0 || value.lifetime[1] < value.lifetime[0] ||
	   value.speed[0] < 0 || value.speed[1] < value.speed[0] ||
	   value.spread < 0 || value.spread > 360 ||
	   value.start_size < 0 || value.end_size < 0 ||
	   value.draw_order < -1000000 || value.draw_order > 1000000 {return false}
	values := []f32{value.rate, value.lifetime[0], value.lifetime[1], value.speed[0],
	              value.speed[1], value.angle, value.spread, value.gravity[0],
	              value.gravity[1], value.start_size, value.end_size}
	for v in values {
		if math.is_nan(v) || math.is_inf(v) {return false}
	}
	return true
}

Particle2D :: struct {
	position, velocity, gravity: [2]f32,
	age, lifetime: f32,
	start_size, end_size: f32,
	start_color, end_color: [4]u8,
}

State :: struct {
	// Borrow particles for reading only, until the next update, emit or destroy.
	particles: [dynamic]Particle2D,
	credit: f64,
	random: u32,
	initialized: bool,
}

destroy :: proc(state: ^State) {
	delete(state.particles)
	state^ = {}
}

// Clear reuses allocated storage and restarts the deterministic random stream.
clear :: proc(state: ^State) {
	resize(&state.particles, 0)
	state.credit = 0
	state.initialized = false
}

// Overflow drops new particles. Storage is bounded by max_particles and reused.
// Origin is in world units; rotation is degrees clockwise in screen coordinates.
// Scale affects diameter only. Existing particles never follow the emitter.
emit :: proc(state: ^State, settings: Emitter2D, count: int, origin: [2]f32,
	rotation: f32 = 0, scale: f32 = 1) -> int {
	if count <= 0 || !valid(settings) {return 0}
	if !state.initialized {
		state.random = settings.seed if settings.seed != 0 else 1
		state.initialized = true
	}
	if state.particles.allocator.procedure == nil {
		buffer, err := make([dynamic]Particle2D, 0, int(settings.max_particles))
		if err != nil {return 0}
		state.particles = buffer
	}
	if cap(state.particles) < int(settings.max_particles) {
		if reserve(&state.particles, int(settings.max_particles)) != nil {return 0}
	}
	available := max(0, int(settings.max_particles) - len(state.particles))
	spawned := min(count, available)
	for _ in 0 ..< spawned {
		angle := (settings.angle + rotation + (random_unit(state) - 0.5) * settings.spread) * (math.PI / 180)
		speed := between(state, settings.speed)
		append(&state.particles, Particle2D{
			position = origin,
			velocity = {math.cos(angle) * speed, math.sin(angle) * speed},
			gravity = settings.gravity, lifetime = between(state, settings.lifetime),
			start_size = settings.start_size * math.abs(scale),
			end_size = settings.end_size * math.abs(scale),
			start_color = settings.start_color, end_color = settings.end_color,
		})
	}
	return spawned
}

// Advance live particles and continuous emission once per simulation update.
// Births are distributed across dt, so low frame rates do not create clumps.
update :: proc(state: ^State, settings: Emitter2D, dt: f32, origin: [2]f32,
	rotation: f32 = 0, scale: f32 = 1) {
	if dt <= 0 || math.is_nan(dt) || math.is_inf(dt) || !valid(settings) {return}
	i := 0
	for i < len(state.particles) {
		particle := &state.particles[i]
		advance(particle, dt)
		if particle.age >= particle.lifetime {
			state.particles[i] = state.particles[len(state.particles) - 1]
			pop(&state.particles)
		} else {i += 1}
	}
	if !settings.emitting || settings.rate == 0 {state.credit = 0; return}
	previous_credit := state.credit
	total := previous_credit + f64(settings.rate) * f64(dt)
	whole := math.floor(total)
	state.credit = total - whole
	// Skip excess births without a backlog or unbounded work on long frames.
	count := int(min(whole, f64(max(0, int(settings.max_particles) - len(state.particles)))))
	for index in 0 ..< count {
		age := f32((f64(count - index - 1) + state.credit) / f64(settings.rate))
		// A guaranteed-dead birth need not allocate storage.
		if age >= settings.lifetime[1] {continue}
		if emit(state, settings, 1, origin, rotation, scale) == 0 {break}
		particle := &state.particles[len(state.particles) - 1]
		advance(particle, age)
		if particle.age >= particle.lifetime {pop(&state.particles)}
	}
}

advance :: proc(particle: ^Particle2D, dt: f32) {
	particle.position += particle.velocity * dt + particle.gravity * (0.5 * dt * dt)
	particle.velocity += particle.gravity * dt
	particle.age += dt
}

appearance :: proc(particle: Particle2D) -> (size: f32, color: [4]u8) {
	t := clamp(particle.age / particle.lifetime, 0, 1)
	size = particle.start_size + (particle.end_size - particle.start_size) * t
	for index in 0 ..< 4 {
		color[index] = u8(clamp(f32(particle.start_color[index]) +
			(f32(particle.end_color[index]) - f32(particle.start_color[index])) * t, 0, 255))
	}
	return
}

@(private)
random_unit :: proc(state: ^State) -> f32 {
	x := state.random
	x ~= x << 13
	x ~= x >> 17
	x ~= x << 5
	state.random = x
	return f32(x >> 8) / 16777216
}

@(private)
between :: proc(state: ^State, range: [2]f32) -> f32 {
	return range[0] + (range[1] - range[0]) * random_unit(state)
}
