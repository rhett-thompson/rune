# Clay UI

`rune:ui` is an optional Odin API over Clay layout and raylib drawing. It supplies
panels, text, buttons, sliders, images, keyboard/gamepad focus, and pointer
capture. UI is currently defined in Odin. Scene/project JSON remains the game
data format; there is no separate UI JSON format yet.

Clay v0.14 is vendored with matching Odin bindings and native libraries. No new
collection flag or install step is needed. See the [source pin and license
information](../third_party/clay/README.rune.md). Windows AMD64 is validated.
Programs that do not import `rune:ui` do not link Clay.

## Example

From the repository root:

```powershell
odin build examples/clay_ui -collection:rune=rune -out:build/clay_ui.exe
./build/clay_ui.exe
```

The demo starts paused. Resume starts the moving orb; A/D moves it horizontally.
Escape or gamepad B opens/closes the menu. Use mouse clicks/drags, Up/Down or
Tab, and Enter. Gamepad D-pad navigates/adjusts and A selects. Left/Right changes
the focused slider in discrete steps. The volume slider controls Rune's master
audio bus; the demo itself has no soundtrack. Resize the window to see Clay
reflow and center the menu. F11 toggles borderless fullscreen. The example uses
a 1280x720 logical window with DPI support enabled; see [display settings](display.md).

## Lifecycle

Keep a `ui.Context` at a stable address for its lifetime. Initialize it after
raylib creates the window, and destroy it in the owning system's shutdown
callback. Do not copy an initialized context. It owns the Clay arena and frame
scratch; it borrows the selected raylib font and any textures.

Rune systems now have a `ui_update` callback. Scene loops call it every rendered
frame after input/console sampling and scene reload, before simulation. It runs
while either game pause or developer-console pause is active. Build and evaluate
UI here, then draw the completed commands in `draw_ui`. Use
`game.frame_delta_time` for UI timing; it is capped at 0.1 seconds and continues
while paused. `game.delta_time` is simulation time and can be zero or the fixed
step interval during console stepping.

```odin
interface: ui.Context // Stable storage; do not return an initialized copy.
menu_open: bool

start :: proc(game: ^rune.Engine, world: ^ecs.World) {
    assert(ui.init(&interface)) // Borrows raylib's default font.
}

ui_update :: proc(game: ^rune.Engine, world: ^ecs.World) {
    controls := ui.read_input(rune.input_state(game))
    controls.blocked = console.is_open(rune.developer_console(game))
    if menu_open || controls.blocked {input.capture(rune.input_state(game))}

    size := [2]f32{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
    if !ui.begin(&interface, size, controls, game.frame_delta_time) {return}
    resume_requested := false
    ui.panel(&interface, "screen", {
        layout = {
            sizing = {width = ui.grow({}), height = ui.grow({})},
            padding = ui.padding(24),
            childAlignment = {x = .Center, y = .Center},
        },
    })
    if menu_open {
        ui.panel(&interface, "menu", {
            layout = {
                sizing = {width = ui.grow({max = 420}), height = ui.fit({})},
                layoutDirection = .TopToBottom,
                padding = ui.padding(24), childGap = 16,
            },
            backgroundColor = {20, 29, 44, 255},
            cornerRadius = ui.corners(8),
        })
        ui.label(&interface, "Paused", interface.style.text, 32)
        resume_requested = ui.button(&interface, "resume", "Resume")
        ui.end_panel(&interface)
    }
    ui.end_panel(&interface)
    if !ui.finish(&interface) {
        console.error(rune.developer_console(game), ui.last_error(&interface))
        return
    }
    if resume_requested {menu_open = false}
    rune.set_paused(game, menu_open)
}

draw_ui :: proc(game: ^rune.Engine, world: ^ecs.World) {
    ui.draw(&interface)
}

shutdown :: proc(game: ^rune.Engine, world: ^ecs.World) {
    ui.destroy(&interface)
}
```

Register these callbacks in the matching `rune.System` fields, including
`draw_ui`, to keep menus at native resolution when the game uses a scaled 2D
canvas. The complete example also handles
opening/closing the menu and captures input on the closing frame so the same
click/key does not reach gameplay. Apply scene changes after `ui.finish`, since
scene shutdown may destroy the UI context.

`rune.set_paused(game, bool)` controls game pause independently of developer
pause. `rune.is_paused` and console `status.paused` report either pause source.
Closing a menu leaves developer pause intact; console `resume` clears developer
pause and leaves game pause intact. Console `step` works under either pause
source. Physics, gameplay updates, cameras, animations and particles stop while
paused. Rendering, UI updates, hot reload, and audio servicing continue; pausing
does not automatically mute or pause audio.

The low-level callback overload of `rune.run` does not dispatch registered
systems. For a custom raylib loop, explicitly run UI layout every frame outside
the simulation pause condition, then call `ui.draw` during drawing.

## Controls and input ownership

| API | Behavior |
| --- | --- |
| `ui.panel(ctx, id, declaration)` / `ui.end_panel(ctx)` | Open/close a Clay layout element. Balance every pair. |
| `ui.scroll_panel(ctx, id, declaration, horizontal = false, vertical = true)` | Open a clipped panel using Clay's scroll position; close with `end_panel`. |
| `ui.label(ctx, text, color, size = 0)` | Wrapped text; zero size uses the context style. |
| `ui.button(ctx, id, text, enabled = true)` | True on pointer release inside the pressed button or focused accept. |
| `ui.slider(ctx, id, &value, min, max, step = 0.05, enabled = true)` | A bar slider; returns true when value changes. Left/right uses `step`; pointer dragging is continuous. |
| `ui.image(ctx, id, texture, size, tint)` | A borrowed texture stretched to a rectangle. |
| `ui.focused(ctx, id)` / `ui.reset_focus(ctx)` | Inspect focus or reset it to the first enabled control on the next build. |
| `ui.bounds(ctx, id)` | Bounds and a found flag from the last completed layout, for tools/tests. |

Use stable, unique IDs across panels and controls. Focus follows enabled controls
in declaration order and wraps. Pointer motion/clicks can take focus; a stationary
pointer does not override keyboard focus. Disabled controls cannot activate and
are skipped in navigation. A press captures its widget until release; releasing
outside a button cancels its activation. Sliders keep dragging outside their
bounds and clamp to their range.

Hit testing uses the previous completed Clay layout, as with Clay's normal
immediate-mode interaction model. A newly shown control needs one completed
layout before pointer hit testing is available. Build once per frame; repeated
`ui.draw` calls do not generate additional button presses or slider changes.
Only one context may be between `begin` and `finish` at a time; multiple contexts
can be built sequentially. Render outside any active 2D/3D camera mode.

`ui.read_input` reads these ordinary Rune input actions: `ui_next`,
`ui_previous`, `ui_accept`, `ui_cancel`, `ui_left`, and `ui_right`. Configure
bindings in input JSON, or supply `ui.Inputs` directly for custom controllers,
replays, or headless tests. `cancel` is an application menu action rather than
an automatic library dismissal. No hardcoded gamepad bindings live in the UI.

`input.capture` gates gameplay `action`, `is_down`, `pressed`, `released`, `strength`,
and `axis` queries for the remainder of the frame. Sampling resets capture next
frame, so visible modal UI must capture every frame. Raw raylib input remains
ungated. This is a single modal capture gate, not a general stack of input maps.

UI uses `input.frame_action`, which ignores capture and consumes injected UI
edges even while simulation is paused. Read each UI action once per frame and
pass the resulting `ui.Inputs` to the context that owns input. Use
separate action names for UI and gameplay; injected gameplay edges retain their
existing simulation-step behavior.

## Appearance, fonts, scrolling, and custom drawing

Edit `ctx.style` for widget colors, text size, button height, and corner radius.
`ui.Element` aliases Clay's element declaration, exposing its sizing, padding,
alignment, floating anchors, clipping, borders, and background configuration.
`ui.grow`, `fit`, `fixed`, `percent`, `padding`, and `corners` mirror the Clay
helpers. Percentage values are 0–1. Application code can compose these primitives
into more specialized controls.

Pass a borrowed font to `ui.init`, including one obtained from Rune's asset
manager. `ui.set_font` changes the font before layout and clears Clay's text
measurement cache when the font identity changes. Text measuring/drawing uses
raylib's UTF-8 functions; available glyphs depend on the loaded font. One font is
used per UI context in this first version. Call `set_font` after asset refresh
before using a hot-reloaded font, and keep all borrowed assets alive through draw.

For scroll panels, use `ui.scroll_panel` with a constrained viewport height/width
and declare its children normally. The wrapper applies Clay's stored scroll
position and the wheel deltas passed to `begin`. Keyboard focus does not yet
automatically scroll a control into view. Direct Clay access is available through the vendored Odin package;
do not call its `BeginLayout`/`EndLayout` inside a Rune-owned layout. The renderer
intersects nested scissors and restores the outer clip after each inner one.

The renderer handles rectangles with independent corner radii, borders, text,
rectangular images, and nested clipping. Images are stretched without rounded
image masking. `ui.draw(ctx, custom_callback)` supports Clay custom commands;
an unhandled custom command returns false with `ui.last_error`. Keep custom draw
callbacks free of gameplay mutations.

## Validation

```powershell
odin build tools/ui_validation -collection:rune=rune -out:build/ui_validation.exe
./build/ui_validation.exe
./build/ui_validation.exe --runtime
```

Headless checks cover the native ABI/layout, resizing, focus traversal, disabled
widgets, clicks and canceled clicks, dragging, bounded memory, context ownership,
input capture, UI input while paused, and independent pause/step controls.
`--runtime` adds hidden-window pixel checks for rendering and nested clipping.
The main validation script discovers this validator and builds the example with
`-AllExamples`. Text entry, dropdowns, accessibility APIs, automatic directional
spatial navigation, and a UI editor are outside this first integration.
