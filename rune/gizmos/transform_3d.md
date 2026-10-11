# Interactive 3D transform handles

`transform_3d.odin` provides screen-space move/rotate handles for a visible
raylib camera. It does not own selection, input, scene entities or undo history.
The layout, picking and drag helpers require no graphics context. Only drawing
calls raylib's graphics API.

Create a layout with the **same camera and complete screen dimensions used to
render the view**:

```odin
layout, visible := gizmos.transform_layout_3d(camera, pivot, screen_size)
hover := gizmos.transform_hit_3d(layout, mode, mouse)
gizmos.draw_transform_3d(layout, mode, hover, active_handle)
```

Call drawing outside 3D camera mode. A scissor rectangle can keep the overlay
out of an inspector. Move mode has three world-axis arrows and a center square
for camera-plane movement. Rotate mode has three world-axis rings. The default
radius is approximately 85 pixels regardless of camera distance.

At mouse press, preserve the authored position/rotation and create a drag:

```odin
drag, started := gizmos.transform_begin_drag_3d(layout, mode, hover, mouse_ray)
```

Keep the layout and baseline fixed for the duration of that drag. Each sample
returns displacement or angle **from the initial sample**, so snapping can be
toggled without accumulated rounding error:

```odin
delta, angle, valid := gizmos.transform_drag_3d(&drag, mouse_ray)
if valid {
    if snapping {
        for &component in delta {component = gizmos.snap_value(component, move_step)}
        angle = gizmos.snap_value(angle, rotation_step)
    }
    position = start_position + delta
    rotation = gizmos.rotate_world_3d(start_rotation, drag.handle, angle)
}
```

The application chooses whether to snap world positions, local positions or
displacements, and supplies its own modifier-key state and increment sizes.
Axis drags retain only their axis component. Camera-plane displacements can be
quantized in the camera's right/up basis if they must stay in that plane.

Unusable axis/ray alignments and behind-camera samples return `false`; leave
the previous preview unchanged. Nearly edge-on rotation rings use a projected
tangent fallback. Other rings use signed, unwrapped angular samples, allowing
multiple revolutions. `rotate_world_3d` composes the turn with the existing
orientation using the same Euler convention as `ecs.compose_transform_3d`.

Run the focused checks from the repository root:

```powershell
odin test rune/gizmos -collection:rune=rune -collection:r3d=third_party/r3d-odin -linker:msvc -o:none
```
