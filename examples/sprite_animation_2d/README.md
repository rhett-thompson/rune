# Sprite Animation 2D

Play sprite-sheet clips and queue a return to idle after short animations.

**Controls:** Tab changes the knight's clip. Space reverses the coin animation.

**Try editing:** [animations/knight.animation.json](animations/knight.animation.json): frame sequences and timing. [animations/coin.animation.json](animations/coin.animation.json): coin playback. [main.odin](main.odin): clip switching.

Run from the repository root on Windows:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = '.exe'
odin run examples/sprite_animation_2d -o:none -linker:msvc -collection:rune=rune "-out:build/sprite_animation_2d$exe"
```

[All examples](../README.md)
