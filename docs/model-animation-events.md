# Skeletal animation events

`ModelAnimator.events` optionally references a reusable, project-relative
`*.model-events.json` file. Tracks use the exact embedded model clip names and
times in **clip seconds**, independent of playback speed or imported tick rate:

```json
{
  "ModelRenderer": {"model": "assets/robot.glb"},
  "ModelAnimator": {"clip": "walk", "events": "assets/robot.model-events.json"}
}
```

```json
{
  "clips": {
    "walk": [
      {"time": 0.2, "name": "footstep"},
      {"time": 0.7, "name": "footstep"}
    ],
    "attack": [{"time": 0.35, "name": "impact"}]
  }
}
```

List markers in nondecreasing time order. Times must be finite, nonnegative,
and no greater than their embedded clip's duration. Each track may contain up
to 4,096 markers, and names must be nonempty. An empty track emits nothing;
clips without a track also emit nothing. An empty `events` path disables markers.
An empty `ModelAnimator.clip` uses the actual first imported clip name to select
its track. Marker names carry no engine behavior: Odin decides what they mean.

## Update and consumption

Keep the optional R3D bridge in the game's simulation `update`, then consume
events from `post_animation`, before the scene loop services particles/audio:

```odin
update :: proc(game: ^rune.Engine, world: ^ecs.World) {
    // Apply input and select clips first.
    r3d_bridge.update_animations(&bridge, world, rune.asset_manager(game), game.delta_time)
}

post_animation :: proc(game: ^rune.Engine, world: ^ecs.World) {
    for event in ecs.model_animation_events(world) {
        if !ecs.is_alive(world, event.entity) {continue}
        if event.name == "footstep" {
            rune.play_audio(game, world, event.entity, "step")
        }
    }
}
```

Register both callbacks in `rune.System`. Callback-based games consume events
immediately after their bridge update. Advance the bridge once per simulation
update; drawing and captures neither emit nor clear events. Engine pause stops
the simulation callbacks, and console stepping runs them once per step.

`ecs.model_animation_events(world)` returns a borrowed, read-only slice of
`Model_Animation_Event`: `entity`, `model` (asset path), `clip` (resolved name),
`name`, `time` (authored clip seconds), and `reverse`. Reading is nondestructive;
multiple systems can observe the same events. Events are ordered within each
entity; ordering across entities is unspecified. Tied markers follow JSON order
forward and reverse JSON order backward.

The slice and its strings expire at the next bridge `update_animations`, explicit
`ecs.clear_model_animation_events`, or World destruction. Copy entries **and
strings** to retain them longer. Buffer strings are independent of model assets,
marker assets, and component storage, so reload/removal cannot corrupt already
emitted events. A removed entity's event is historical; check its handle before
acting. Sprite and skeletal buffers are separate, so either updater can run
first without erasing the other's events.

## Playback rules

- Initial playback and explicit restart emit a marker exactly at the starting
  position on the first positive-time playing update. Reverse restart starts
  at the clip's end. Pause, zero-time updates, and drawing emit nothing.
- Normal advancement emits every crossed marker, including multiple loops or
  markers skipped by a large update. Reverse traversal reports `reverse = true`.
  Changing speed preserves position; reversing at a marker does not re-emit it.
- `seek_model_animation` is silent, including the destination itself. It never
  replays events between the old position and the destination. Subsequent
  advancement resumes collection from the new position.
- Stop resets to zero without emitting. Resume after stop can emit a zero-time
  starting marker. Ordinary pause/resume preserves traversal.
- During pose blending, only the advancing destination clip emits. The frozen
  source pose emits nothing. Interrupting a blend starts the new destination's
  timeline under the same rules.
- Non-looping clips emit an endpoint marker once and then finish. A loop wrap
  emits both endpoint markers if the asset defines distinct markers at zero and
  duration: duration then zero forward, zero then duration backward. Use one of
  those positions for a single once-per-cycle effect. Exact reverse wraps retain
  `elapsed = duration`; exact forward wraps retain `elapsed = 0`.
- Disabled entities do not advance. Component/clip/autoplay changes that reset
  playback reset marker traversal. Changing only the `events` path preserves
  playback position and emits only subsequent crossings.

Rune advances one seconds-based clock for skeletal playback and marker
collection, then asks R3D to evaluate its pose at that time. Marker collection
therefore uses the same float precision as the displayed playback position.

## Reload, validation, and limits

`hot_reload.animations` also polls loaded marker files. Valid replacements keep
playback position and affect future crossings without replaying history.
Invalid JSON, invalid marker shapes, or missing replacement files keep the
previous working tracks. Model reload preserves the existing playback state
where possible and rechecks tracks against the replacement clip durations.

The project validator checks file existence and marker JSON without graphics.
The R3D bridge additionally diagnoses unknown embedded clip names and times past
a clip's end. An invalid active track emits nothing while the model continues
animating; valid tracks remain usable. This model-dependent check does not roll
back an otherwise well-formed marker file. Runtime diagnostics identify the
marker file and track.

At most 4,096 skeletal events are retained per bridge update. Excess events are
dropped, playback still advances, and
`ecs.model_animation_events_overflowed(world)` becomes true until the next clear.
This also bounds traversal work for extreme speeds and long custom-loop updates.
Do not silently ignore overflow if these events drive critical gameplay.

Try the [skeletal demo](../examples/skeletal_animation_3d/README.md): its original
two-joint rig shows impact sparks for `bend` and footstep cues for `sway`. Tests
live in `tools/model_animation_validation`; the normal run covers marker parsing,
timeline crossings, and ownership, while `--runtime` also verifies R3D poses,
blend behavior, controls, and reloads in a hidden window.
