# Sprite Animation 2D

Play sprite-sheet clips and queue a return to idle after short animations.

**Controls:** Tab changes the knight's clip. Space reverses the coin animation.

**Try editing:** [animations/knight.animation.json](animations/knight.animation.json): frame sequences and timing. [animations/coin.animation.json](animations/coin.animation.json): coin playback. [main.odin](main.odin): clip switching.

Run from the repository root with PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/sprite_animation_2d -collection:rune=rune "-out:build/sprite_animation_2d$exe"
```

[All examples](../README.md)
