# Directional shadow rendering regression

This GPU fixture measures rendered shadow contrast and receiver acne, beyond
checking shadow matrix stability. It uses the normal Rune scene renderer with
a 0.2 m floor caster and 0.2/0.5 m wall casters. The vertical receiver faces a
directional sun at a grazing angle (`N dot L` approximately 0.15).

From Rune's repository root on Windows:

```powershell
odin build tools/shadow_render_probe -collection:rune=rune -collection:r3d=third_party/r3d-odin -linker:msvc -out:build/shadow-render-probe.exe
./build/shadow-render-probe.exe
```

Omit `-linker:msvc` on Linux. The fixture creates a hidden window and requires
an actual OpenGL GPU context. Output goes to `build/shadow-render-probe`.
An optional first argument selects another output directory.

The default run asserts 13 shadow-enabled/disabled render pairs using depth
bias 0.00005 and slope bias 0.0001. It verifies measurable shadow area and
contrast from thin casters, a clean grazing receiver without other casters,
and a known lit reference region above the caster's shadow. Material cases
cover normal-mapped deferred shading, builtin alpha forward shading,
normal-mapped forward shading, and a custom circle surface shader. Texture,
material, and custom-shader loading are checked so fallback rendering cannot
silently satisfy these cases.

Each pair writes PNGs and numerical measurements in `results.json`. A pixel
is counted as visibly shadowed when its luminance drops by more than 10 out
of 255. The lit wall reference samples 425 fixed world positions above the
caster and its downward shadow. Default checks require no false reference
shadow samples, at most four false shadow pixels on an otherwise unoccluded
receiver, and at least 100 visibly shadowed pixels from each thin caster.

For a diagnostic sweep of older biases, ranges, and caster sizes without the
default pass/fail assertions:

```powershell
./build/shadow-render-probe.exe build/shadow-render-sweep broad
```

An additional `8192` argument doubles the directional shadow map resolution
for comparison. These diagnostic arguments do not change engine or game
settings. Generated fixture materials, normal textures, images, and reports
remain in the selected output directory. The tool does not read game saves.
