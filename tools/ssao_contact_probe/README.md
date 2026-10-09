# Contact shading through animated FOV

This actual GPU fixture measures contact-band width at fixed world positions.
It covers a continuous floor/wall joint and three finite pillars, with centered
and off-axis contacts. Camera position and orientation remain fixed while the
visible lens traverses 70 to 74 degrees and back in 21 states.

```powershell
odin build tools/ssao_contact_probe -collection:rune=rune -collection:r3d=third_party/r3d-odin -linker:msvc -out:build/ssao-contact-probe.exe
./build/ssao-contact-probe.exe build/ssao-contact-baseline baseline
./build/ssao-contact-probe.exe build/ssao-contact-stable stable
```

Add `quick` after the mode for the landscape wall fixture only. Otherwise the
tool also covers 959x539 and 541x769 render sizes. A hidden OpenGL window and
actual GPU are required. It does not read or write game saves.

Both modes use SSAO world radius 2, intensity 0.8, 64 samples, bias 0.03, and
`ssao_reference_fovy=70`. The stable mode additionally supplies
`sampling_fovy=75.8`. Each viewport/geometry pair runs SSAO alone, SSGI alone,
and SSAO with SSGI active. SSGI uses four slices, four denoising passes,
distance falloff 0.25, and intensity 1. The latter two cases use ACES exposure
0.65 and the game's color adjustments, with an unshadowed directional light
providing indirect-light input. Directional shadows, other effects, and
anti-aliasing are disabled to isolate contact shading.

Each floor and wall profile has 241 points spaced 5 mm apart, beginning 5 mm
from the contact. Five fixed world positions along the edge are averaged at
each distance. The tool uses bilinear pixel reconstruction and registers
against the actual rounded presentation viewport. A screen-pixel box average
would introduce its own changing world footprint during lens animation.

The normal-output comparisons report widths at 1%, 2%, 4%, and 8% shading and
at fractions of the baseline peak. They follow the connected contact band
outward from its peak. The combined case toggles SSAO while retaining SSGI in
both images; the SSGI-only case measures its added illumination.

Native SSAO and SSGI visualizations provide an independent control. Those
outputs use the complete native sampling projection, without the final crop.
Their fixed-world profiles and contour widths show whether the source effect
itself changes. The stable criteria require native profile drift no larger
than one 8-bit color step, contour movement no larger than one 5 mm profile
bin, and native image differences no larger than one color step. The baseline
must violate that contact-footprint criterion; reproducing the known issue is
a successful baseline run. `stable_criteria_passed` records the actual verdict.

Presented SSAO contours at 4% and 8% shading must remain within two pixels of
the geometry registration; the combined ACES/SSGI comparison allows three.
The 1–2% crossings are reported separately and are not pass criteria: their
color difference can be only one or two 8-bit steps, so small interpolation
changes can move a shallow threshold crossing a large distance. SSGI-only
presentation contours also remain diagnostic because its small illumination
signal is quantized. Native source invariance distinguishes this presentation
uncertainty from a changing effect footprint. Contact contrast must remain
visible, and every return to FOV 70 must restore pixel-identical on/off images.
Each draw also verifies restoration of the authored upscale filter.

`frames.json` contains every dense profile; `sweeps.json` contains the metrics
and verdicts. PNGs at the first, widest, and returning lens include on/off scene
images and the native effect source. On the checked Windows GPU the fixed
sampling SSAO sources and all their contact contours are exactly invariant.
Baseline SSAO native contour shifts are 1.36–1.72 cm across the six
geometry/viewport pairs; fixed sampling reduces them to zero. A few SSGI
pixels elsewhere change by one color step, while contact contour shifts remain
zero. The standalone presented SSAO dark contours remain within 1.62 pixels;
the combined comparison reaches 2.72 pixels.
