# Distant SSAO upsampling during FOV animation

This GPU regression renders large, unoccluded flat and four-degree sloped
planes from a horizontal camera 1.7 meters above the floor. It measures 203
fixed world positions: 29 depths from 8 to 256 meters and seven lateral
positions covering the center and both viewport edges. FOV follows
70 → 72 → 74 → 70 at 960×540, 959×539, and 541×769.

From Rune's root on Windows:

```powershell
odin build tools/ssao_upsample_probe -collection:rune=rune -collection:r3d=third_party/r3d-odin -linker:msvc -out:build/ssao-upsample-probe.exe
./build/ssao-upsample-probe.exe build/ssao-upsample-probe
```

Omit `-linker:msvc` on Linux. The fixture requires an actual GPU and opens a
hidden window. Its only argument chooses the output directory. It does not
read or write game saves.

Each case exports the normal scene with SSAO enabled, the same scene with
SSAO disabled, and the raw SSAO debug buffer. SSAO uses world radius 2,
screen radius cap 0.2, bias 0.03, intensity 0.8, and 64 samples. The draw uses
reference FOV 70. Other screen-space lighting, directional shadows, fog,
bloom, grain, and anti-aliasing are disabled.

`results.json` stores each world sample's projected pixel, AO-on/off
luminance, and raw occlusion. `sweeps.json` summarizes fixed-world FOV changes
and counts changed pixels after returning to FOV 70. The assertions require:

- Less than 0.25/255 false shading or raw occlusion at every world sample.
- At most 1/255 channel difference between AO-on/off across the complete
  image, and at most 1/255 raw occlusion anywhere on an unoccluded plane.
- Less than 0.25/255 shading change at corresponding world positions during
  FOV animation, and pixel-identical on/off/raw images after returning.
- All 203 samples and the expected image dimensions at every viewport.

This catches a bilateral upsampling failure that near-corner tests missed.
At grazing depths, all four depth weights could become very small. Dividing
by a clamped denominator reduced their normalized sum, so a homogeneous
white AO buffer became dark in the final lighting. FOV changes moved the
failure between distant surface pixels even though the raw AO stayed white.

On the original Windows implementation, the sloped plane showed up to
64.44/255 false darkening and a 54.44/255 change at the same world position
between FOV 70 and 74. After stable weight normalization and selected-depth
pixel reconstruction, all 4,872 world samples and all six return sweeps
were exact zero in the measured GPU run. The companion
[`ssao_fov_probe`](../ssao_fov_probe/README.md) checks that genuine corner
contact shading remains present while the reference lens preserves its
strength.
