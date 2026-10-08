# Navigation 3D

A clickable navigation course with an obstacle, a ramp, an upper platform, and
a disconnected island. The blue capsule follows a NavAgent3D route through
CharacterController3D. The gold line shows the smoothed route through the current
triangle corridor. Agents travel straight across open floor and turn at passage
corners, with surface crossings retained at ramp seams.

The agent turns its facing at up to 360°/second, accelerates at 8 units/s², and
brakes at 6 units/s². Destination braking and corner slowdown are enabled, so it
slows before sharp turns and settles at the goal. A facing marker and the HUD's
actual speed and remaining route distance make the movement settings visible.
Ramp steering follows each straight route section, and facing follows the
requested heading. Ground contact keeps stopped agents settled on the slope.
Speed is measured along the surface, so the ramp retains the configured cruise
speed while the HUD includes its vertical motion.
The controller's intermediate waypoint tolerance is 0.08 units; final arrival
uses 0.12 units and waits until speed falls to 0.05 units/s or less. Change these
settings on the `agent` entity in `scenes/main.scene.json`; direct Transform agents
use `NavAgent3D.acceleration` and `.braking` instead of the motor's values.

The on-screen Movement panel adjusts speed, acceleration, braking, turning
speed, stopping distance, waypoint tolerance, and maximum slope while running
or paused. Its toggles enable facing, destination braking, and corner slowdown.
Speed and slope changes also update the capsule motor's matching limits. The
45° slope range matches this course's bake; lowering it below the ramp's angle
makes the ramp unavailable to the agent. Turning speed zero holds facing.
Reset movement settings restores the scene values loaded at startup. Hide/Show
collapses the panel to expose more of the course. Slider
changes last for the session and do not write the scene file. Mouse input over
the panel or during a slider drag is reserved for the panel.

```powershell
odin run examples/navigation_3d -linker:msvc -collection:rune=rune
```

| Control | Action |
| --- | --- |
| Left click | Pick a destination on a permitted triangle. |
| Right drag | Orbit around the current view target. |
| Mouse wheel | Zoom in/out, with distance limits. |
| Middle drag | Pan the view. |
| F | Center the orbit on the agent. |
| R | Restore the original course view. |
| B | Block/reopen the lower half of the ramp. This changes navigation only. |
| M | Toggle triangle edges. |
| Space | Cancel the route. |
| P | Pause/resume movement. |
| N | Rebake navigation from the current scene, including live edits. |
| C | Toggle cube placement mode; left-click places at the preview. |
| Z | Undo the most recently placed cube. |

The HUD uses the shared Inter font and shows the actual ramp state. The console
command `ramp` performs the same toggle as B. Closure stays synchronized through
scene reloads and navmesh rebakes.

Camera controls work while paused. Left-click destinations use the current camera
view, and dragging the camera does not issue movement commands.
Orbit, zoom, and pan use the shared OrbitCamera3D controller. Panning tracks the
pointer at the current view distance, field of view, and window height.

In placement mode, aim at a floor, ramp or cube top. A green preview marks a clear
spot; red marks an overlap. Each 1.5-unit cube has static collision and immediately
rebakes navigation. Agents keep their destinations and replan around the new
obstacle. Undo also rebuilds navigation, and failed bakes roll back the edit.
Placement works while paused, supports up to 64 cubes, and prevents overlapping
the agent or existing objects. Console equivalents are `cube [4,2,0]` (coordinates
on the supporting surface) and `undo_cube`.

Placed cubes are session edits. They survive manual rebakes but are not written
to the scene file; restarting or fully reloading the scene discards them.

Click the upper platform to traverse the ramp. Click the separate island to see
an unreachable query. Closing the ramp invalidates the route; reopening it lets
the agent retry. The B control demonstrates logical route blocking without a
physical door, so avoid closing the region directly beneath the agent.

The demo bakes its own navigation from static scene colliders at startup, before
loading the generated asset. It can start without `course.baked.navmesh.json`.
Scene reloads and save restores also rebake automatically. Press **N** or use the
console command `rebake` after live geometry edits or bake-setting changes; this
works while paused. Manual rebakes retain active destinations and the ramp's closed state.
A failed bake keeps the previous mesh and reports the error in the HUD/console.

The example reads the `settings` object from `course.navbake.json`, bakes its
current world, and writes the asset referenced by its `navigation` entity. The
standalone tool remains optional:

```powershell
odin run tools/navmesh_baker -linker:msvc -collection:rune=rune -- examples/navigation_3d/course.navbake.json
```

`course.navbake.json` uses 0.25-unit cells, 0.4 units of radius clearance and
2 units of headroom. The bake removes the obstacle footprint and insets ledges.
Simplification is enabled by default and merges the course from 6,608 cell
triangles to 34 triangles without changing those clearance settings. Add
`"simplify": false` to the settings to skip merging, then press N or run `rebake`.
The original hand-authored `course.navmesh.json` and `generate_mesh.bat` / `generate_mesh.sh` remain
as a separate authoring reference. Rendering uses raylib directly for the mesh and debug capsule; this
example does not need r3d. See the [navigation guide](../../docs/navigation-3d.md)
for the API, authoring rules, and current limits.

The console command `navigate` sets the upper platform as the destination.

The engine command `navmesh on` adds the shared translucent navigation overlay,
with triangle edges and red blocked triangles. `navmesh on navigation` selects
this demo's navigation entity; `navmesh off` hides the overlay. This works through
the console inbox and is independent of the demo's M edge toggle and F3 gizmos.

Run the demo's baking and ramp/reload regressions with
`odin test examples/navigation_3d -collection:rune=rune` from the repository root.

