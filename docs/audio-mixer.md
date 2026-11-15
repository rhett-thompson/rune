# Audio mixer buses

Each Rune audio system owns a runtime mixer with `master`, `music`, `sfx`, and
`ui` buses. All start at volume 1, unmuted. Scene audio routes through SFX unless
`AudioPlayer.bus` specifies another bus:

```json
"AudioPlayer": {
  "theme": { "sound": "assets/theme.ogg", "bus": "music", "volume": 0.7,
             "looping": true, "play_on_start": true }
}
```

```odin
import "rune:audio"

audio.set_bus_volume(&game.audio.mixer, .master, 0.8)
audio.set_bus_volume(&game.audio.mixer, .music, 0.5)
audio.mute_bus(&game.audio.mixer, .sfx, true)
audio.fade_bus(&game.audio.mixer, .music, 0, 2.0)
```

Volumes range from 0 to 1. Setters reject invalid values and return success.
Gain is player volume (including per-voice variation) times distance attenuation
times bus volume times master volume. Players routed directly to master apply
master once. Mute preserves the slider value. A new linear fade replaces the
previous fade starting at the current value; setting volume cancels a fade.

Spatial audio measures XYZ distance between the emitter and listener's composed
3D world positions, including ancestor translation, rotation, and scale. The
distance settings are world units. Gain is full through `min_distance`, then
falls linearly to silence at `max_distance`. Stereo pan follows the source's
direction relative to the listener: a listener with `Camera3D` uses that
camera's world-space `target` and `up`; a standalone listener uses its composed
Transform's local +X axis as right. Turning or rolling the camera updates pan
for every active voice. Nonspatial players stay centered and unattenuated.
Both entities require their own `Transform`. This is stereo positioning and
distance falloff; it does not add geometry occlusion or HRTF processing.

Changes affect buffered sounds, all overlapping aliases, looping sounds, and
streaming music on the next audio update. A newly played sound uses the current
gain immediately. Scene loops advance fades using frame time even when gameplay
is paused. For manually managed audio call `audio.update(&system, &world, dt)`;
the optional third argument defaults to zero for compatibility.

Bus settings survive scene changes in the same Engine. They are not saved and
do not alter authored player volumes. Raw raylib playback bypasses the mixer;
raylib's own master gain is an additional output gain if the game changes it.

The Audio Components example demonstrates SFX controls: M toggles mute, F fades
out over two seconds, R restores volume, and left-click plays the bell. The Clay
example's volume slider controls the master bus.

## Room reverb

Set a bus's room send from the game thread with `audio.set_bus_reverb`. The
send defaults to zero and accepts finite values from 0 through 1. The call
returns whether the value was accepted.

```odin
audio.set_bus_reverb(&game.audio, .sfx, 0.3)
// On leaving the room, stop feeding the reverb and let its tail decay.
audio.set_bus_reverb(&game.audio, .sfx, 0)
```

The stereo return is added to the existing dry signal. It follows source
volume, distance attenuation and stop fades, and the bus and master control
its output gain and mute. Buffered voices, loops, and streaming players all
feed the selected bus. The send smooths changes and the return keeps ringing
after a source stops. Rune sends affect only players on the selected bus. Raw
raylib playback bypasses the effect. Games supply the room send for the current
listener environment and reset it on scene changes as appropriate.

The first nonzero send claims the process-wide raylib mix processor for that
audio system until shutdown. A nonzero request needs a live device and returns
`false` if another audio system already owns the processor. Up to 256 native
playback streams feed the effect at once. Finished streams free their slots
for reuse, and playback continues dry if all slots are in use.

## Audio device lifetime

`audio.init` opens raylib's process-wide audio device only when it is not already
ready. `Audio_System.owns_device` is true only when that system successfully
opened the device; an existing device is borrowed. `audio.shutdown` releases the
system's playback resources and closes the device only when the system owns it.
Failed initialization leaves both `available` and `owns_device` false.

Keep the device owner alive until all borrowing audio systems have shut down.
The Engine owns its audio system for its full lifetime, including scene changes
and quickloads; game code using that device should leave it open until shutdown.

## Continue playback across scenes

Scene replacement normally removes the old World's players on the next audio
update. To continue an existing track or buffered voices, author a compatible
`AudioPlayer` in the destination scene and rebind its playback during the
destination's start/reload callback, before that update:

```odin
rune.rebind_audio(&game, new_world, previous_owner, "theme", next_owner, "theme")
// The direct audio-system API is audio.rebind(&system, new_world, ...).
```

Retain only the previous entity handle and instance name, then reacquire the
destination entity from the new World. The old World may already be destroyed.
The destination must be live and use the same `sound`, ordered `clips`, and
`buffered` settings. A missing source or occupied destination leaves both
players unchanged. Rebinding to the same compatible key succeeds unchanged.

The audio system moves ownership of the decoder, cursor, selected clip, buffered
aliases, suspension and pending stop fade without playing, stopping or reloading.
Destination volume, bus, looping and spatial settings apply during normal audio
servicing; mixer gains/fades stay intact. Removing the destination releases the
resources normally. Games own which transitions preserve a player; do not fade
or explicitly play that player when seamless continuation is intended.
For a move within one World, remove the source `AudioPlayer` before servicing
audio so its separate autoplay setting cannot start another instance.

The serial `rune/audio` tests cover ownership and rejected transfers without a
device. `tools/mixer_validation --runtime` additionally exercises the actual MP3
decoder and buffered aliases across World destruction.

## Fade out on stop

Set `AudioPlayer.fade_out_on_stop` to fade a named player's active playback to
silence before stopping it. The duration is seconds, must be finite and
nonnegative, and defaults to `0` for an immediate stop.

```json
"AudioPlayer": {
  "motor": { "sound": "assets/motor.ogg", "looping": true,
             "fade_out_on_stop": 0.5 }
}
```

```odin
rune.stop_audio(&game, entity, "motor") // Use the component's duration.
rune.stop_audio(&game, entity, "motor", 1.0) // Override this stop to one second.
rune.stop_audio(&game, entity, "motor", 0) // Stop immediately.
```

The optional duration on `rune.stop_audio` and `audio.stop` defaults to `-1`,
which uses the configured duration. A finite nonnegative override applies only
to that stop and leaves the component unchanged. Other negative or nonfinite
durations are rejected.

`rune.audio_is_stopping` / `audio.is_stopping` report a pending fade. Playback
remains active until the fade finishes; an explicit play cancels the fade.

The linear fade applies to the streaming channel and every active buffered
voice, independently of bus fades and distance attenuation. It advances using
frame time passed to `audio.update`, including while gameplay is paused. Repeated
stop calls leave an existing fade's deadline unchanged. An explicit play cancels
the pending stop and starts playback at the normal player gain. Removing the
player or shutting down the audio system still releases playback immediately.
An explicit stop also suppresses `play_on_start` from automatically restarting
the player until another explicit play or a source configuration change.

```powershell
# Windows PowerShell; on Linux omit .exe and -linker:msvc, and use ./build/...
New-Item -ItemType Directory -Force build | Out-Null
$exe = '.exe'
odin build tools/mixer_validation -linker:msvc -collection:rune=rune "-out:build/mixer_validation$exe"
& "./build/mixer_validation$exe"
& "./build/mixer_validation$exe" --runtime
```

## Random clip players

An `AudioPlayer` can use an arbitrary-length `clips` array instead of a single
`sound`. Each explicit `rune.play_audio`/`audio.play` call (and initial autoplay)
chooses an entry uniformly. Consecutive repeats are allowed; duplicate entries
weight the selection. A non-empty list overrides `sound`; an empty list requires
a valid `sound` fallback.

```json
"AudioPlayer": {
  "footsteps": {
    "clips": ["assets/step_1.ogg", "assets/step_2.ogg", "assets/step_3.ogg"],
    "buffered": true,
    "volume": 0.5,
    "random_pitch": 0.04,
    "max_voices": 4
  }
}
```

Buffered clips load on first selection or preload. Players in the same audio
system share one decoded sample buffer for each configured path. Each player
and overlapping voice has independent playback, volume, pitch, pan and
reverb routing. Samples are released after their last player is removed.
Overlapping plays share `max_voices` across all clips; when full, the oldest
voice is replaced. Mixer changes affect every voice, including older clips.
Changing `sound`, `clips`, or `buffered` replaces the old resources on the next
update or play. Volume and pitch edits keep the selected clip. Typed
setters copy clip lists, which survive scene snapshots and reloads.

Ogg Vorbis and other streaming formats use one playback channel by default.
Selecting another stream or switching between a stream and buffered sound
replaces the previous playback. Set `buffered: true` on short compressed clips
to decode them into memory and allow overlapping voices.
Looping repeats the selected clip until the next explicit play; it does not
randomize the clip at each loop boundary. Sources and aliases are released when
the player is removed or the audio system shuts down.
