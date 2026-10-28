# Gamepad input

Rune's input mappings combine keyboard, mouse, and controller bindings into
named actions. Most examples use pad 0; Pong and Tanks also use pad 1. The
launcher, UI stick navigation, and default hold-START exit scan pads 0–3.
Example READMEs list their controller controls and remaining pointer interactions.

## Buttons and axes

```json
{
  "$schema": "../../../schemas/input.schema.json",
  "actions": {
    "jump": [{ "type": "keyboard", "key": "SPACE" },
             { "type": "gamepad_button", "button": "A" }],
    "fire": [{ "type": "gamepad_button", "button": "RIGHT_TRIGGER" }]
  },
  "axes": {
    "move_pad": { "type": "gamepad_axis", "axis": "LEFT_X", "deadzone": 0.15 }
  }
}
```

Button names are `A`, `B`, `X`, `Y`, `DPAD_UP`, `DPAD_DOWN`, `DPAD_LEFT`,
`DPAD_RIGHT`, `LEFT_BUMPER`, `RIGHT_BUMPER`, `LEFT_TRIGGER`, `RIGHT_TRIGGER`,
`BACK`, `START`, `LEFT_THUMB`, and `RIGHT_THUMB`. They describe raylib's
logical Xbox-style layout; physical labels vary. `LEFT_TRIGGER` and
`RIGHT_TRIGGER` buttons use raylib's digital trigger buttons, suitable for fire
or sprint without converting a signed analog trigger axis into a boolean.

Axes are `LEFT_X`, `LEFT_Y`, `RIGHT_X`, `RIGHT_Y`, `LEFT_TRIGGER`, and
`RIGHT_TRIGGER`. Stick Y is normally positive downward; use `invert` when the
game's positive direction is upward/forward. Optional `gamepad` selects a slot,
defaulting to 0. A deadzone in `[0, 1)` removes drift and rescales the remaining
range to full deflection. Start near 0.15 and tune on the actual device.
Unavailable controllers produce zero and are checked again every frame.

Trigger ranges depend on the platform/controller mapping. For a signed trigger
whose idle value is -1 and full pull is +1, pressure is `(value + 1) / 2`.
Check live values with `pads`; do not use that conversion for a different range.
Stick deadzone logic is centered at zero and does not convert signed trigger
polarity. Prefer trigger buttons for discrete actions.

## Combine desktop and controller input

Keep keyboard movement and controller movement in separate axes:

```odin
movement := clamp(input.axis(controls, "move") + input.axis(controls, "move_pad"), -1, 1)
position.x += movement * movement_speed * game.delta_time
look := input.axis(controls, "look_x") * mouse_sensitivity +
        input.axis(controls, "look_x_pad") * 180 * game.delta_time
```

Mouse deltas are displacement since the last frame; stick values describe a
continuous rate and need frame time. Match each stick axis's `invert` setting
to its mouse counterpart. Clamp 2D movement only when its length exceeds 1 so
partial stick deflection retains partial speed. `input.capture` gates gameplay
actions and axes while a modal UI owns input.

`OrbitCamera3D` consumes `orbit_x_pad` and `orbit_y_pad` while `orbit_camera`
is held, plus `zoom_in` and `zoom_out` actions. Defaults are 180 degrees/second
and 8 world units/second. Empty or unbound names are inactive. See the
[component fields](components.md#orbitcamera3d) for customization.

## Menu navigation

```odin
controls := ui.read_input(&menu, rune.input_state(game), game.frame_delta_time)
```

The UI context stores independent repeat state. It combines mapped `ui_next`,
`ui_previous`, `ui_left`, and `ui_right` actions with the strongest left stick
across pads 0–3. Defaults are a 0.6 threshold, a 0.35-second initial delay, and
a 0.14-second repeat. Set `menu.nav.threshold`, `delay`, and `repeat` to tune it.
`ui_accept` and `ui_cancel` remain ordinary rebindable actions.

Programs without an engine can use `input.nav_update(&state, dt)` directly.
`input.nav_edges(&state, stick, dt)` is the pure equivalent for synthetic input.
Only the dominant axis emits; neutral/disconnect resets the hold and direction
changes emit immediately. At most one repeat occurs per sample.

## Device activity and cursor visibility

`input.update` fills `controls.activity` each frame, independently of action
mappings and `input.capture`. Its `mouse_moved`, `mouse_button_or_wheel`, and
`gamepad` flags describe physical activity, including pads 0–3 used by menus.
Gamepad buttons use press/release edges, including digital trigger buttons, so
signed analog triggers resting at -1 do not count as activity. Sticks use a 0.2
deadzone and meaningful changes; drift and a stationary hold do not claim
activity. A newly connected or reconnected controller establishes a baseline;
buttons already held at connection do not count as activity until a later
press or release. Invalid stick values are ignored.

Games can opt in with `rune.set_gamepad_cursor_auto_hide(game, true)`; the default
is disabled. Gamepad activity hides a free pointer in gameplay, menus, and the
console. Mouse movement, button input, or scrolling reveals it, with mouse input
winning when both devices act in the same frame. Keyboard input does not change
this visibility policy. Hide/reveal does not warp or capture the pointer, and
the requested `.visible`, `.hidden`, or `.captured` gameplay mode stays separate.
`rune.cursor_mode(game)` still returns that requested mode.
Use `rune.set_cursor_mode` consistently with auto-hide: a later raw raylib capture
cannot be distinguished from a pointer that is already hidden by gamepad use.

The engine samples and applies this policy in `rune.begin_frame`. Custom loops
call `input.update(rune.input_state(game))`, then `rune.sync_cursor_activity(game)`;
keep the [console cursor hooks](runtime-console.md#cursor-ownership) when updating
the console directly. Normal `rune.shutdown` always restores a visible, free cursor.

## Exit, saved bindings, and diagnostics

Hold START on a single controller for one second to request engine exit. This
works during pause and without an input mapping document. A tap still performs
its mapped action. Focus loss, release, disconnect, and
`rune.set_gamepad_exit(game, false)` reset the timer. Re-enable with `true`.
Projects may omit `input` or use an empty string when no mappings are needed.

`input.rebind_keyboard` preserves other device bindings. `input.save` retains
the loaded `$schema` and emits type-specific JSON, without unrelated zero
fields. Integral axis scales are saved as integers. The
[runtime-rebinding example](../examples/runtime_rebinding/README.md) demonstrates it.

For arbitrary keyboard/mouse/gamepad slots, owned menu drafts, atomic live
configuration replacement, and canonical capture names, see
[Input rebinding](input-rebinding.md).

The console's `pads` command reports connected pad indexes, names, axis counts,
and live axes. `quit` requests immediate exit and acknowledges remote requests
before closing. In a running game's file-console inbox:

```sh
sh tools/console.sh --directory build/console --command pads --json
sh tools/console.sh --directory build/console --command quit --json
```

For Steam Input use a gamepad layout, then confirm live axes and buttons in the
running application. These changes have automated Windows/Linux checks where
recorded in [Linux development](linux.md), but have not been tested on a
physical controller or Steam Deck. Follow the [Deck checklist](steam-deck.md#device-verification)
before recording hardware support. Haptics and platform-specific controller
behavior remain dependent on the bundled raylib backend.
