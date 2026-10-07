// Allocation diagnostics for Rune-owned storage. These are backing-buffer
// sizes, not process RSS, driver allocations, or allocator bookkeeping.
package memory

import "base:runtime"
import "core:encoding/json"
import "core:mem"

Arena_Stats :: struct {
	block_bytes, out_band_bytes, bookkeeping_bytes: u64,
	unknown_out_band_allocations: int,
}

arena_stats :: proc(arena: ^mem.Dynamic_Arena) -> Arena_Stats {
	if arena == nil {return {}}
	blocks := len(arena.used_blocks) + len(arena.unused_blocks)
	if arena.current_block != nil {blocks += 1}
	result := Arena_Stats{
		block_bytes = u64(blocks * arena.block_size),
		bookkeeping_bytes = u64((cap(arena.used_blocks) + cap(arena.unused_blocks) + cap(arena.out_band_allocations)) * size_of(rawptr)),
	}
	for allocation in arena.out_band_allocations {
		info := mem.query_info(allocation, arena.out_band_allocations.allocator)
		if bytes, found := info.size.?; found {result.out_band_bytes += u64(bytes)}
		else {result.unknown_out_band_allocations += 1}
	}
	return result
}

map_bytes :: proc(values: $M/map[$K]$V) -> u64 {
	if cap(values) == 0 {return 0}
	return u64(runtime.map_total_allocation_size_from_value(values))
}

// Includes owned JSON strings, keys, array capacity, and map backing storage.
json_bytes :: proc(value: json.Value) -> u64 {
	#partial switch node in value {
	case json.String: return u64(len(node))
	case json.Array:
		bytes := u64(cap(node) * size_of(json.Value))
		for item in node {bytes += json_bytes(item)}
		return bytes
	case json.Object:
		bytes := map_bytes(node)
		for key, item in node {bytes += u64(len(key)) + json_bytes(item)}
		return bytes
	}
	return 0
}
