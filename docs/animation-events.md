# Sprite animation events

Animation clips can carry named frame markers. JSON describes their timing;
Odin gameplay code decides what each name means. Markers can synchronize audio,
damage, projectile release, and particle bursts with sprite playback.

```json
"strike": {
  "frames": [8, 9, 10, 11],
  "fps": 12,
  "loop": false,
  "markers": [
    {"frame": 1, "name": "swing"},
    {"frame": 2, "name": "impact"}
  ]
}
```

`frame` is a zero-based position in this clip's `frames` array. Here `impact`
occurs upon entering atlas frame 10. List markers in nondecreasing frame order;
multiple markers at one frame keep their JSON order. Names must be nonempty,
frames must be in range, and a clip may have at most 4,096 markers. The loader,
project validator, and animation schema support the optional `markers` array.
Existing animation assets need no changes.

## Consuming events

Register a `post_animation` system callback to react during the same simulation
tick, after sprite animation advances and before particles, lifetimes, and audio:

```odin
handle_animation :: proc(game: ^rune.Engine, world: ^ecs.World) {
    for event in ecs.sprite_animation_events(world) {
        if !ecs.is_alive(world, event.entity) {continue}
        if event.name == "impact" {
            // Apply game-owned damage rules and trigger effects here.
        }
    }
}

rune.register_system(&game, rune.System{
    name = "animation_effects",
    post_animation = handle_animation,
})
```

Each `Sprite_Animation_Event` contains `entity`, `animation` (asset path), `clip`,
`name`, and `frame`. Events are chronological within one entity; ordering across
entities is unspecified. Reading is nondestructive, so several systems can
observe the same buffer. Process it once per simulation update in
`post_animation`; fixed-update and draw callbacks are unsuitable consumers.
Engine pause skips animation advancement and `post_animation`; console stepping
runs both once per requested simulation update.

The returned slice and its strings are borrowed read-only until the next
`render.update_sprite_animators`, `ecs.clear_sprite_animation_events`, or World
destruction. Copy entries **and strings** if retaining them longer. Events own
their text independently of assets and component strings, so asset reloads,
clip changes, and component/entity removal do not corrupt already-emitted events.
A removed entity's event is historical; check its handle before acting on it.
Scene replacement destroys the old World and its buffer.

Callback loops call `render.update_sprite_animators(world, manager, dt)` once
per simulation update, then consume the events before drawing. It clears the
previous buffer automatically, even when no animator advances. Do not also call
it when using Rune's scene loop. Advanced headless tools can use
`render.advance_sprite_animation` with resolved clip data, clearing the buffer
once before advancing all entities.

## Playback rules

- A marker on the starting frame fires on the first positive-time update with
  playback enabled and speed greater than zero. Zero-time refreshes emit nothing.
- Every crossed marker fires, including frames skipped by a long update and
  multiple loop crossings. Wrapping into frame zero fires its markers again.
- Non-looping clips emit final-frame markers once, then hold their last pose.
  Rune's existing completion rule remains: multi-frame clips finish when they
  enter the final frame; a single-frame clip finishes after one frame duration.
- Pause emits nothing and preserves traversal. Resume continues from there.
  Speed changes preserve fractional clip progress. Authored/runtime speed
  settings must be positive; low-level advancement also ignores zero,
  negative, or nonfinite speed/time values.
- Restart, stop followed by resume, clip/asset/autoplay changes, and successful
  animation-asset reloads reset traversal. Restarting schedules starting-frame
  markers for the next advancing update. `restart = false` on the current clip
  does not re-emit them. Queued clips follow the same rules when they start.
- A successful asset reload resets to frame zero while preserving the existing
  playing/paused state. It does not replay the old timeline. An invalid reload
  keeps the previous clip and markers. Disabled entities do not advance.

The World buffers at most 4,096 events per animation update. Excess events are
dropped and `ecs.sprite_animation_events_overflowed(world)` returns true until
the next clear. Playback still reaches its final position. This bounds memory
and processing for extreme playback speeds or long custom-loop updates. Keep
gameplay workloads below that limit and check overflow when diagnosing missed
events. No event callbacks run during traversal, so handlers cannot invalidate
an animator while it is advancing.

This API covers sprite clips. [Skeletal animation events](model-animation-events.md)
use a separate buffer with the same consumption and ownership pattern.

## Example and validation

Try [Animation Events 2D](../examples/animation_events_2d/README.md) from the
launcher. Its footsteps, roll-strike damage, and particles follow animation
speed. `tools/sprite_animation_validation` covers parsing, ordered events,
multiple loops, one-shots, speed changes, pause, overflow, and asset reload.
`--runtime` adds real asset resolution, queues, component edits, activation,
and entity removal with a hidden raylib window. It is included in
`tools/validate.ps1 -AllExamples`; add `-Runtime` for graphics checks.
