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

Changes affect buffered sounds, all overlapping aliases, looping sounds, and
streaming music on the next audio update. A newly played sound uses the current
gain immediately. Scene loops advance fades using frame time even when gameplay
is paused. For manually managed audio call `audio.update(&system, &world, dt)`;
the optional third argument defaults to zero for compatibility.

Bus settings survive scene changes in the same Engine. They are not saved and
do not alter authored player volumes. Raw raylib playback bypasses the mixer;
raylib's own master gain is an additional output gain if the game changes it.
This first mixer has four fixed buses and linear gain fades; it has no effects,
automatic ducking, or track scheduler.

The Audio Components example demonstrates SFX controls: M toggles mute, F fades
out over two seconds, R restores volume, and left-click plays the bell. The Clay
example's volume slider controls the master bus.

```powershell
odin build tools/mixer_validation -collection:rune=rune -out:build/mixer_validation.exe
./build/mixer_validation.exe
./build/mixer_validation.exe --runtime
```
