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
caller. This pass uses raylib rendering and does not inherit R3D world lighting.
Direct presentation with `end_overlay_3d` occurs after world post-processing.
Rune's `examples/first_person_3d/weapon.odin` demonstrates
camera-local transforms and shaded geometry.

For foreground models that should receive scene post-processing, provide
`r3d_bridge.Scene3D_Settings.scene_overlay`. Its callback runs before the R3D
scene session and receives the physical framebuffer dimensions. Render with
`begin_overlay_3d`, then call `finish_overlay_3d` to end the isolated pass without
presenting. Return the layer's borrowed `target.texture`:

```odin
draw_foreground :: proc(data: rawptr, framebuffer: [2]i32) -> r3d_bridge.Scene_Color_Overlay {
    if !render.begin_overlay_3d(&layer, foreground_camera,
                               framebuffer[0], framebuffer[1]) {return {}}
    // Draw the foreground model here, using its own camera and depth.
    render.finish_overlay_3d(&layer)
    return {color=layer.target.texture}
}

view := r3d_bridge.Scene3D_Settings{scene_overlay=draw_foreground}
r3d_bridge.draw_scene_ex(&bridge, world, manager, view)
// Draw the HUD afterward.
```

The bridge converts the captured display-encoded color to scene-linear HDR and
composites it after world fog and transparency, before bloom, exposure,
tonemapping, color adjustment, anti-aliasing and film grain. Set `linear_color`
when both input textures already contain linear color. A separate emission mask
may be returned with `emission` and `emission_energy`; its RGB adds radiance to
the scene and feeds ordinary world bloom. Black geometry in that mask still
occludes hidden emitters using its own depth.

Texture ownership stays with the caller through `draw_scene_ex`. Color textures
use premultiplied RGB with coverage alpha; `Overlay3D` captures this convention
and `end_overlay_3d` presents it correctly. Additive particles contribute RGB
without adding coverage. A zero/invalid color texture skips composition for the
frame, so unloaded or hidden models cannot leave an earlier frame visible.
The bridge maps sampling-lens crops back to the visible framebuffer; foreground
projection remains stable during scene FOV changes and render-scale adjustments.

This route does not replace scene depth or normals. World SSAO and fog retain
their world geometry, while model self-occlusion uses its isolated depth. Later
depth-driven effects such as DOF still sample world depth. Games needing a
separate foreground focus policy should avoid world DOF for that composition.

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
odin run tools/overlay_3d_validation -linker:msvc -collection:rune=rune -out:build/overlay_3d_validation.exe -- --runtime
```

The hidden-window check verifies world depth isolation, self-occlusion, clear and
transparent pixels, HUD ordering, resize and resource cleanup.

For the R3D composition checks, compile and launch separately:

```powershell
tools/odin.bat build tools/scene_overlay_validation -linker:msvc -collection:rune=rune -collection:r3d=third_party/r3d-odin -out:build/scene_overlay_validation.exe
build/scene_overlay_validation.exe
```

The hidden-window check verifies shared color adjustment, exposure and bloom,
sampling-crop alignment, isolated depth, HUD ordering, missing-frame handling,
premultiplied transparency and additive particles.
