# Audio Components

Play scene-authored audio and hear attenuation as an emitter moves away from its listener.

**Controls:** Left-click plays the bell; M toggles SFX mute; F fades SFX; R restores SFX volume.

**Try editing:** [scenes/main.scene.json](scenes/main.scene.json): listener and audio players. [main.odin](main.odin): emitter movement and mixer controls.

Run from the repository root with PowerShell 7:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
$exe = if ($IsWindows) { '.exe' } else { '' }
odin run examples/audio_components -collection:rune=rune -collection:r3d=third_party/r3d-odin "-out:build/audio_components$exe"
```

[All examples](../README.md)
