# Animation Events 2D

A small training scene connects JSON sprite markers to Odin gameplay. Walk to
the target and roll-strike it. The `impact` marker applies 10 damage and creates
a sound and particle burst. Run markers trigger footsteps and dust. Change
playback speed to see the timing stay attached to the animation.

| Control | Action |
| --- | --- |
| A / D | Walk left / right |
| Space | Roll strike (within 150 units of the target) |
| Tab | Cycle 0.5x, 1x, 2x, and 4x speed |
| P | Pause/resume the knight's animation |
| R | Restore target health and hit count |

Build from the repository root, putting the executable in `build/`:

```powershell
$suffix = if ($IsWindows) { '.exe' } else { '' }
odin build examples/animation_events_2d -collection:rune=rune "-out:build/animation_events_2d$suffix"
& "./build/animation_events_2d$suffix"
```

Edit `animations/knight.animation.json` while running to move or rename markers.
`main.odin` handles them in `post_animation`, after sprite playback and before
particle/audio servicing. Target health is a game-defined Odin component and
is inspectable through the console. No damage, audio, or particle behavior is
encoded into marker JSON.

Art and sounds reuse the bundled CC0 Brackeys platformer pack; see
`../assets/brackeys_platformer_assets/LICENSE & CREDITS.txt`. Typography uses the
shared Inter font. See [the event API](../../docs/animation-events.md) for buffer
lifetime, playback rules, and limits.
