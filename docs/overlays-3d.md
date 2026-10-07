# 3D overlays

`rune:render.Overlay3D` owns a transparent color target and a separate depth
buffer. Use it for first-person models that should remain visible against nearby
world geometry. Model faces still depth-test against each other.

In a system's `draw_ui`, after Rune presents the world/reference canvas:

```odin
if render.begin_overlay_3d(&layer, {
    position={}, target={0,0,-1}, up={0,1,0},
    fovy=55, projection=.PERSPECTIVE,
}) {
    // Draw camera-local 3D geometry or raylib models here.
    render.end_overlay_3d(&layer)
}
// Draw the HUD afterward.
```

The default target follows the physical framebuffer and is composited at logical
screen size, including high-DPI windows. Optional width/height and destination
arguments support explicit sizes. Resizing recreates the attachments. Call
`destroy_overlay_3d` before closing the graphics context. Neither nested overlay
passes nor drawing inside an active reference canvas is supported. The caller
must also avoid nesting other raylib texture/3D modes.

Geometry, animation, model ownership, camera placement and lens stay with the
caller. This pass uses raylib rendering and does not inherit R3D world lighting
or post-processing. Rune's `examples/first_person_3d/weapon.odin` demonstrates
camera-local transforms and shaded geometry.

For an emission mask, draw non-emissive geometry black to establish depth, then
draw the emitting surfaces in their emission colors. Present that layer with
`end_overlay_3d(&emission_layer, glow={strength=2, radius=3})`. The optional glow
uses additive composition and a small Gaussian filter. Black mask pixels add
no light, and hidden emitters remain occluded by mask depth. `radius` is in
target pixels; compact radii of 2–4 suit thin model accents. `strength` scales
emission radiance during composition. This separate effect does not alter the
R3D world bloom settings. Shader and texture ownership remain with the layer.

GPU checks (run from the Rune root):

```powershell
odin run tools/overlay_3d_validation -collection:rune=rune -out:build/overlay_3d_validation.exe -- --runtime
```

The hidden-window check verifies world depth isolation, self-occlusion, clear and
transparent pixels, HUD ordering, resize and resource cleanup.
