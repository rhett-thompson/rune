# Animation transitions

Transition decisions remain ordinary Odin gameplay code. There is no state graph
or behavior encoded in JSON in this first implementation.

## Sprite clips

```odin
ecs.play_sprite_animation(world, knight, "roll")
ecs.queue_sprite_animation(world, knight, "idle")
```

One pending clip starts on the update after a non-looping clip finishes. Looping
clips never consume the queue. A newer queue request replaces the previous one;
an empty name cancels it. Stop or restarting/changing a clip clears it. Pausing
does not count as completion. `Sprite_Animation_State.finished` distinguishes
natural completion from a pause/stop.

Queued clips use the same animation asset. The renderer checks the queued name
when it is consumed; a missing clip reports an asset diagnostic and leaves the
finished pose intact. The queue and completion state are runtime data. For
continuous state selection, `play_sprite_animation(..., restart = false)` avoids
resetting a clip already selected. The Sprite Animation example queues idle
after roll and hit. Sprite transitions switch frames; they do not alpha-blend
two sprites.

## Skeletal clips

```odin
ecs.transition_model_animation(world, actor, "run", 0.25)
```

Requests for the already-selected clip do nothing, so this can be called from
an update condition. A zero duration switches immediately. Negative/nonfinite
durations fail without changing playback. Names are resolved against the model
by the renderer, using the existing missing-clip diagnostics.

Alternatively set `ModelAnimator.blend_time` in JSON or Odin (default 0), and use
the existing `play_model_animation` or clip setter. On a clip change, the bridge
captures the currently displayed local bone pose and blends toward the new,
advancing animation. Translation/scale interpolate linearly; rotations use
quaternion slerp. The source pose is frozen during the blend. This keeps
interrupted transitions continuous without managing a stack of outgoing clips.

Blends advance only in `r3d_bridge.update_animations`; drawing never advances
time. Pausing playback freezes the blend, and resume continues it. If the new
non-looping clip finishes early, the blend can still finish toward its final
pose. Temporary pose storage is freed at completion, interruption, component
removal, model reload, or shutdown. This supports ordinary TRS bone transforms;
it is not an animation graph, additive layer system, or root-motion controller.

The Skeletal Animation example blends between keys 1 and 2 over 0.35 seconds.
Its P/R pause/resume controls also demonstrate freezing and resuming a blend.

```powershell
odin build tools/model_animation_validation -collection:rune=rune -collection:r3d=third_party/r3d-odin -out:build/model_animation_validation.exe
./build/model_animation_validation.exe --runtime
odin build tools/sprite_animation_validation -collection:rune=rune -out:build/sprite_animation_validation.exe
./build/sprite_animation_validation.exe --runtime
```
