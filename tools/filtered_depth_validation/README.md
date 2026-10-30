# Filtered depth validation

From the Rune root, build with the compiler guard and run the executable separately:

```powershell
./tools/odin.ps1 -OdinArguments @('build','tools/filtered_depth_validation','-collection:rune=rune','-collection:r3d=third_party/r3d-odin','-linker:msvc','-out:build/filtered-depth-validation.exe')
./build/filtered-depth-validation.exe
```

The hidden-window fixture requires a graphics context. It verifies that omitting
a foreground beam preserves the included wall behind it, leaves empty sky clear,
and does not remove the beam from normal scene color/depth. It also checks
material cutouts, vertex deformation, explicit shader time, internal-resolution
changes, and resource cleanup. Captures and generated fixture assets are saved
under `build/filtered-depth-validation/`.

The shaft probe uses emissive lit materials so geometry writes opaque depth
before pre-transparency effects. It checks that filtering exposes sky around
the rear wall, that the shaft shader samples the alternate depth, and that
returning to the ordinary entry point restores the original effect without
another auxiliary pass. An unlit-wall check confirms that filtering preserves
the native opaque depth pass's existing material participation.
