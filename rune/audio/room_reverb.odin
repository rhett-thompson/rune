package audio

@(private)
Room_Reverb :: struct {
	storage: []f32,
	delays: [4][]f32,
	positions: [4]int,
	damped: [4]f32,
	damping, smoothing: f32,
}

@(private)
init_room_reverb :: proc(room: ^Room_Reverb, sample_rate: int) -> bool {
	if sample_rate <= 0 {return false}
	delay_ms := [4]int{19, 27, 34, 43}
	lengths: [4]int
	total := 0
	for duration, i in delay_ms {
		lengths[i] = max(1, duration * sample_rate / 1000)
		total += lengths[i]
	}
	storage, err := make([]f32, total)
	if err != .None {return false}
	room.storage = storage
	offset := 0
	for length, i in lengths {
		room.delays[i] = storage[offset:offset + length]
		offset += length
	}
	room.damping = min(1, 1 / (0.00006 * f32(sample_rate)))
	room.smoothing = min(1, 1 / (0.035 * f32(sample_rate)))
	return true
}

// A damped four-delay feedback network. Different delay lengths and opposing
// output signs diffuse the sound and give the shared room return stereo width.
@(private)
room_reverb_sample :: proc "contextless" (room: ^Room_Reverb, input: f32) -> [2]f32 {
	delayed: [4]f32
	for &value, i in delayed {
		value = room.delays[i][room.positions[i]]
		room.damped[i] += room.damping * (value - room.damped[i])
		if abs(room.damped[i]) < 0.00000001 {room.damped[i] = 0}
	}
	a, b, c, d := room.damped[0], room.damped[1], room.damped[2], room.damped[3]
	// A normalized Hadamard matrix with a feedback gain of 0.72.
	feedback := [4]f32{a + b + c + d, a - b + c - d, a + b - c - d, a - b - c + d} * 0.36
	for delay, i in room.delays {
		position := room.positions[i]
		delay[position] = input + feedback[i]
		position += 1
		if position == len(delay) {position = 0}
		room.positions[i] = position
	}
	a, b, c, d = delayed[0], delayed[1], delayed[2], delayed[3]
	return [2]f32{a + b - c + d, a - b + c + d} * 0.36
}
