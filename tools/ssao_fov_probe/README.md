# SSAO during a changing field of view

This actual GPU fixture renders deterministic floor/wall corners and isolated
flat and sloped planes through Rune's normal scene renderer. It uses the game's
SSAO settings: world radius 2, screen radius cap 0.2, intensity 0.8, bias 0.03,
and 64 samples. Directional shadows, SSIL, SSGI, fog, bloom, grain, and
anti-aliasing are disabled so the measurements isolate SSAO.

From Rune's root on Windows:

```powershell
odin build tools/ssao_fov_probe -collection:rune=rune -collection:r3d=third_party/r3d-odin -linker:msvc -out:build/ssao-fov-probe.exe
./build/ssao-fov-probe.exe build/ssao-fov-baseline
./build/ssao-fov-probe.exe build/ssao-fov-compensated compensated
```

Omit `-linker:msvc` on Linux. A hidden OpenGL window and actual GPU are required.
The first argument selects an output directory; it defaults to
`build/ssao-fov-probe`. The optional `compensated` argument passes Rune's
`Scene3D_Settings.ssao_reference_fovy = 70` to the actual scene renderer. The
renderer temporarily applies the camera-relative screen-radius cap:

```text
max_radius = 0.2 * tan(70 degrees / 2) / tan(current_fov / 2)
```

Each run writes 48 SSAO-enabled/disabled PNG pairs: four scenes, three viewport
shapes (800x600, 960x540, 600x800), and FOV 70, 72, 74, then 70 again. It samples
fixed world positions projected through the current camera, averaging a 3x3
pixel neighborhood at each point. `results.json` contains the samples;
`sweeps.json` summarizes each four-frame sweep. Comparing the same world
positions avoids confusing the expected movement of geometry with changing
occlusion strength.

Every run requires visible corner contact shading, less than 0.25 luminance
change on unoccluded flat/sloped plane samples, and a pixel-identical return to
FOV 70. Both modes check that the authored ECS radius cap remains 0.2 and the
native environment cap is restored after every draw. The baseline must expose
a greater than 5% near-corner regional AO pulse. The compensated run limits it
to 0.12 luminance units and 3%, and contact-line change to 0.4 luminance units.
The small tolerance allows changes in raster placement and the SSAO noise
pattern. These checks preserve actual contact shading while rejecting a
projection-induced strength pulse.

The measured uncompensated 70-to-74 change in the near-floor region was 8.6%,
10.2%, and 13.1% across the three viewports. Compensation reduced it to -0.3%,
1.5%, and -0.2%. The farther corner remains outside the screen-radius cap and
serves as a control: its renders are unchanged by compensation. This tool
does not read or write game saves or authored post-processing settings.
