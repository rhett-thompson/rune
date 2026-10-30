# Filtered scene depth

`rune:r3d_bridge` can render an auxiliary depth buffer while omitting selected
entity subtrees. Selection belongs to the calling game and does not alter
material files, renderer components, entity activation, or the normal scene
depth buffer. Objects behind excluded geometry still contribute their own
depth.

## Use with scene effects

```odin
ignored := [1]ecs.Entity{decorative_effect_root}
filter := r3d_bridge.Depth_Pass_Filter{ignored_subtrees=ignored[:]}
ok := r3d_bridge.draw_scene_with_filtered_depth(
    &bridge, world, asset_manager, scene_settings, filter,
)
```

`ignored_subtrees` is borrowed through the call. Each live root excludes itself
and its descendants, including descendants reached through grouping entities
without transforms. Empty lists, zero/stale handles, disabled subtrees, and
subtrees without supported rendered geometry do not request an auxiliary pass.
Games must reacquire entity handles after scene replacement or restoration.

This additive entry point preserves the existing `draw_scene_ex` signature and
`Scene3D_Settings` layout. The built-in screen-space light shafts currently use
the auxiliary depth when their effect is active and the filter excludes enabled
rendered geometry. Without those conditions the original path remains in use,
with no extra depth target allocation or pass. Other native effects continue to
use the main scene depth.

The normal color and depth draws still contain the excluded objects. A filtered
pass omits their geometry from the auxiliary draw; it does not erase their
pixels from an already rendered depth image. This retains rear-wall depth and
prevents light leaking through architecture hidden behind an excluded object.

## Use the depth texture directly

```odin
depth_pass: r3d_bridge.Depth_Pass3D
// Keep depth_pass alive across frames; destroy it before graphics shutdown.
// Call after preparing scene geometry and animation caches for this draw.
valid := r3d_bridge.render_scene_depth(
    &depth_pass, &bridge, world, asset_manager, camera, filter, material_time,
)
if valid {
    depth_texture := depth_pass.target.texture
    // Bind this borrowed texture to the consuming effect.
}
```

The texture's red channel contains positive linear view-space Z in world units,
not normalized hardware depth or Euclidean camera distance. It uses the native
internal render resolution, with bottom-left texture coordinates and the
far-plane distance in clear pixels. The camera and sampling projection must
match the consuming draw; `draw_scene_with_filtered_depth` handles that match for its
built-in consumer.

The pass uses ordinary geometry and material submission, retaining opaque and
alpha-cutout depth, vertex shader deformation, animated model poses, and
terrain. It copies the native opaque linear-depth attachment used by
`FetchDepth`, preserving existing material participation: unlit forward draws
and alpha surfaces do not become occluders because they appear in later raw
hardware depth. Normal CPU
occlusion is bypassed for the auxiliary draw because removing an occluder can
reveal geometry that was hidden in the main scene.

Cloud volumes and code-owned particle batches are not part of this opaque depth
pass; they do not write the normal opaque scene depth either. Standalone calls
require prepared terrain, static-mesh, and animation caches for the intended
draw. The integrated scene entry point prepares those caches automatically.

`render_scene_depth` returns false and clears `valid` for an ineffective filter,
uninitialized renderer, unavailable native hooks, or a failed pass. Check its
return value every draw rather than reusing a previous frame's pixels.
An earlier target may remain allocated for reuse after failure, but its contents
are invalid whenever `valid` is false.
`pass_count` counts successful auxiliary renders. The helper uses the same
native-hook target support as `render_view_3d`: Windows and Linux amd64;
unsupported targets return false.

`Context.filtered_depth` is renderer-owned and released by bridge shutdown.
`frame_stats.filtered_depth_passes` and `filtered_depth_cpu_ms` report the
auxiliary work; ordinary scene draw counts remain separate. Both are zero
when the integrated effect does not need a filtered pass.
Separately created `Depth_Pass3D` values belong to the caller: reuse them across
frames and call `destroy_depth_pass_3d` before closing the graphics context.
Resizing or destroying a pass invalidates borrowed textures. Rendering and
cleanup run on the graphics/World owner thread, outside an active R3D session.

See `rune/r3d_bridge/filtered_depth_test.odin` for CPU filtering/default-path
checks. Runtime verification should include an excluded foreground object over
an included wall, an excluded object over empty sky, matching camera sampling,
and resource resize/cleanup.

The Windows amd64 GPU fixture is `tools/filtered_depth_validation`. Build it
with Rune's compiler guard, then run its executable separately as described in
that tool's README. It checks rear-wall preservation behind an excluded static
mesh, actual shaft-sampler selection and restoration of the ordinary path,
normal scene color/depth, unchanged unlit-material participation, material
cutouts and vertex animation, native target
resizing, and resource cleanup. Linux runtime coverage remains separate.
