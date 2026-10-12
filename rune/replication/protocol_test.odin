package replication

import "core:math"
import "core:slice"
import "core:testing"

@(test)
input_wire_fixture_and_validation :: proc(t: ^testing.T) {
	fixture := [INPUT_SIZE]u8{1, 1, 0x01, 0x23, 0x45, 0x67, 0xff, 1}
	value, ok := decode_input(fixture[:])
	testing.expect(t, ok && value == Input_Command{0x01234567, {-1, 1}})
	buffer: [INPUT_SIZE+1]u8
	size, encoded := encode_input(value, buffer[:])
	testing.expect(t, encoded && size == INPUT_SIZE && slice.equal(buffer[:size], fixture[:]))
	for size in 0 ..< INPUT_SIZE {_, valid := decode_input(fixture[:size]); testing.expect(t, !valid)}
	_, valid := decode_input(buffer[:])
	testing.expect(t, !valid, "trailing payload bytes are rejected")
	for index in ([4]int{0, 1, 6, 7}) {
		bad := fixture
		bad[index] = 2
		_, valid := decode_input(bad[:])
		testing.expect(t, !valid, "unknown version/kind and axes outside [-1,1] are rejected")
	}
	_, valid = encode_input(Input_Command{axis = {-2, 0}}, buffer[:])
	testing.expect(t, !valid)
	_, valid = encode_input(value, buffer[:INPUT_SIZE-1])
	testing.expect(t, !valid)
}

@(test)
snapshot_wire_fixture_and_validation :: proc(t: ^testing.T) {
	fixture := [23]u8{
		1, 2, 0x89, 0xab, 0xcd, 0xef, 1,
		0x01, 0x23, 0x45, 0x67, 0x76, 0x54, 0x32, 0x10,
		0x3f, 0xc0, 0, 0, 0xc0, 0x10, 0, 0,
	}
	value, valid := decode_snapshot(fixture[:])
	testing.expect(t, valid && value.tick == 0x89abcdef && value.count == 1)
	testing.expect(t, value.states[0] == State{0x01234567, 0x76543210, {1.5, -2.25}})
	buffer: [MAX_SNAPSHOT_SIZE+1]u8
	size, encoded := encode_snapshot(value, buffer[:])
	testing.expect(t, encoded && size == len(fixture) && slice.equal(buffer[:size], fixture[:]))
	for size in 0 ..< len(fixture) {_, valid := decode_snapshot(fixture[:size]); testing.expect(t, !valid)}
	_, valid = decode_snapshot(buffer[:size+1])
	testing.expect(t, !valid, "trailing bytes are rejected")
	for index in ([3]int{0, 1, 6}) {
		bad := fixture
		bad[index] = 255
		_, valid := decode_snapshot(bad[:])
		testing.expect(t, !valid)
	}
	for offset in ([2]int{7, 11}) {
		bad := fixture
		for index in offset ..< offset+4 {bad[index] = 0}
		_, valid := decode_snapshot(bad[:])
		testing.expect(t, !valid, "zero network identities and owners are rejected")
	}
	for bits in ([3]u32{0x7fc00000, 0x7f800000, 0xff800000}) {
		bad := fixture
		write_u32(bad[15:19], bits)
		_, valid := decode_snapshot(bad[:])
		testing.expect(t, !valid, "non-finite wire coordinates are rejected")
	}
	duplicate := value
	duplicate.count = 2
	duplicate.states[1] = duplicate.states[0]
	_, valid = encode_snapshot(duplicate, buffer[:])
	testing.expect(t, !valid)
	copy(buffer[23:39], buffer[7:23])
	buffer[6] = 2
	_, valid = decode_snapshot(buffer[:39])
	testing.expect(t, !valid, "duplicate wire IDs are rejected before applying")
	for count in ([2]int{-1, MAX_ENTITIES+1}) {
		invalid := value
		invalid.count = count
		_, valid := encode_snapshot(invalid, buffer[:])
		testing.expect(t, !valid)
	}
	for number in ([3]f32{math.nan_f32(), math.inf_f32(1), math.inf_f32(-1)}) {
		invalid := value
		invalid.states[0].position[1] = number
		_, valid := encode_snapshot(invalid, buffer[:])
		testing.expect(t, !valid)
	}
	_, valid = encode_snapshot(value, buffer[:size-1])
	testing.expect(t, !valid)
	empty_size, empty_encoded := encode_snapshot(Snapshot{tick = 2}, buffer[:])
	empty, empty_valid := decode_snapshot(buffer[:empty_size])
	testing.expect(t, empty_encoded && empty_valid && empty_size == 7 && empty.count == 0 && empty.tick == 2)
	maximum := Snapshot{tick = 3, count = MAX_ENTITIES}
	for index in 0 ..< MAX_ENTITIES {maximum.states[index] = State{u32(index+1), 1, {f32(index), -f32(index)}}}
	maximum_size, maximum_encoded := encode_snapshot(maximum, buffer[:])
	maximum_copy, maximum_valid := decode_snapshot(buffer[:maximum_size])
	testing.expect(t, maximum_encoded && maximum_valid && maximum_size == 135 && maximum_copy == maximum,
		"the maximum room snapshot fits into one relay payload and supports multiple entities per owner")
}

@(test)
serial_numbers_compare_across_wrap :: proc(t: ^testing.T) {
	testing.expect(t, sequence_newer(10, 9))
	testing.expect(t, !sequence_newer(10, 10) && !sequence_newer(9, 10))
	testing.expect(t, sequence_newer(0, 0xffffffff) && sequence_newer(2, 0xfffffffe))
	testing.expect(t, !sequence_newer(0xffffffff, 0) && !sequence_newer(0x80000000, 0) && !sequence_newer(0, 0x80000000))
}
