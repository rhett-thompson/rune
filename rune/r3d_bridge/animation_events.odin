package r3d_bridge

import "core:fmt"
import "core:math"
import "core:strings"
import "rune:assets"
import "rune:ecs"
import r3d "r3d:r3d"

// Advance Rune's seconds-based clock and collect crossings from that same
// interval. R3D evaluates the resulting pose; no second native clock is advanced.
advance_model_timeline :: proc(
	world: ^ecs.World, entity: ecs.Entity, model, clip: string,
	state: ^ecs.Model_Animation_State, animator: ecs.ModelAnimator,
	markers: []assets.Model_Animation_Marker, dt: f32,
) {
	if world == nil || state == nil || !state.playing || dt <= 0 ||
	   !ecs.finite_nonnegative(dt) || state.duration <= 0 ||
	   !ecs.finite_nonnegative(state.duration) || animator.speed == 0 ||
	   math.is_nan(animator.speed) || math.is_inf(animator.speed) {return}
	reverse := animator.speed < 0
	boundary_already_emitted := state.marker_boundary_crossed
	start := f64(state.elapsed)
	duration := f64(state.duration)
	travel := f64(dt) * math.abs(f64(animator.speed))
	if !animator.loop {travel = min(travel, start if reverse else duration - start)}
	end := start - travel if reverse else start + travel
	if animator.loop {
		end = math.mod(end, duration)
		if end < 0 {end += duration}
	}
	// Match the precision of the published/native clock before collecting
	// crossings, including values that round onto a marker or wrap boundary.
	rounded := f64(f32(end))
	travel = max(0, travel + (end - rounded if reverse else rounded - end))
	end = rounded
	if animator.loop {
		if reverse && end == 0 {end = duration}
		if !reverse && end == duration {end = 0}
	} else if end <= 0 && reverse || end >= duration && !reverse {
		state.playing = false
		state.finished = true
	}
	state.elapsed = f32(end)
	state.marker_boundary_crossed = animator.loop && travel > 0 && (end == 0 || end == duration)
	if !state.markers_started {
		state.markers_started = true
		for offset in 0 ..< len(markers) {
			marker := markers[len(markers)-1-offset if reverse else offset]
			if f64(marker.time) == start {
				if !emit_model_marker(world, entity, model, clip, marker, reverse) {return}
			}
		}
	}
	if travel <= 0 || len(markers) == 0 {return}
	for cycle: f64 = 0; ; cycle += 1 {
		for offset in 0 ..< len(markers) {
			i := len(markers) - 1 - offset if reverse else offset
			marker := markers[i]
			distance := start - f64(marker.time) if reverse else f64(marker.time) - start
			distance += cycle * duration
			if distance < 0 || distance == 0 && cycle == 0 {continue}
			if distance == 0 && boundary_already_emitted {continue}
			if distance > travel {return}
			if !emit_model_marker(world, entity, model, clip, marker, reverse) {return}
		}
		if !animator.loop {return}
	}
}

@(private)
emit_model_marker :: proc(world: ^ecs.World, entity: ecs.Entity, model, clip: string, marker: assets.Model_Animation_Marker, reverse: bool) -> bool {
	return ecs.append_model_animation_event(world, {entity, model, clip, marker.name, marker.time, reverse})
}

@(private)
imported_clip_name :: proc(clip: ^r3d.Animation) -> string {
	name := strings.string_from_ptr(cast(^u8)&clip.name[0], len(clip.name))
	end := strings.index_byte(name, 0)
	return name[:end] if end >= 0 else name
}

@(private)
model_event_track :: proc(manager: ^assets.Asset_Manager, path, clip_name: string, library: r3d.AnimationLib) -> []assets.Model_Animation_Marker {
	if path == "" {return nil}
	data, _, loaded := assets.model_events(manager, path)
	if !loaded {return nil}
	// Validate authored tracks against imported names/durations. Parsing remains
	// graphics-free; model-dependent errors identify the exact track at runtime.
	valid := true
	for name, markers in data.clips {
		index := r3d.GetAnimationIndex(library, fmt.ctprintf("%s", name))
		detail: string
		if index < 0 {
			detail = "marker track does not name an embedded clip"
		} else {
			clip := (cast([^]r3d.Animation)library.animations)[index]
			if len(markers) > 0 && markers[len(markers)-1].time > clip.duration / clip.ticksPerSecond {
				detail = "marker time exceeds the embedded clip duration"
			}
		}
		field := fmt.tprintf("$.clips.%s", name)
		if detail != "" {
			assets.report_failure(manager, {kind = .Animation, operation = .Load, source_path = path, field = field, asset_path = path, detail = detail})
			if name == clip_name {valid = false}
		} else {assets.resolve_asset_failure(manager, path, field, path)}
	}
	return data.clips[clip_name] if valid else nil
}
