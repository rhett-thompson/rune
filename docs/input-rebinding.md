# Input configuration ownership and rebinding

`rune:input` supports drafts independently of the engine's live `Input` value.
`input.clone(controls)` validates and copies the complete configuration into a
new owned arena. It retains every action slot, every axis parameter, `$schema`
presence/value, and the originally loaded path. Runtime action samples,
injections, axis samples, and UI capture state are fresh. Destroy an owned draft
with `input.destroy(&draft)` when finished. Copying an `Input` struct directly
does **not** clone its ownership.

```odin
controls := rune.input_state(game)
draft, valid := input.clone(controls)
if !valid {return}
defer input.destroy(&draft)

if !input.rebind(&draft, "jump", 1,
    input.Binding{type="gamepad_button",button="A",gamepad=0}) {return}

if !input.replace_configuration(controls, &draft) {return}
```

`input.rebind(controls, action_name, slot, binding)` replaces an existing,
zero-based slot with a keyboard, mouse-button, or gamepad-button binding. It
preserves all other slots and axes; it neither adds slots nor removes bindings.
Invalid inputs, action names, slot indexes and bindings leave the configuration
unchanged. Stored strings belong to the input arena, so supplied binding strings
may come from temporary UI storage. This operation changes configuration only;
draft state, conflict rules and persistence remain game-owned.

`input.replace_configuration(target, source)` clones and validates before
destroying the target's former configuration. The `^Input` address stays stable,
and the source remains independently usable. Self replacement is supported.
An invalid source leaves both target configuration and runtime state untouched.
On success, action samples, injected actions and axis samples are empty and
gameplay queries are captured for the remainder of that rendered frame. Native
input is sampled normally at the next `input.update`.

For an application that must save preferences before committing the live
configuration, prepare an owned clone first, validate/save it through the game's
chosen persistence path, then call `input.move_configuration(target, &prepared)`.
This installation allocates nothing, transfers the arena, and zeroes the source
on success. Runtime reset and frame capture match `replace_configuration`.
Source and target must be distinct, independently owned values. Accidental
shallow aliases sharing an arena are rejected by both installers.

`input.save` continues to write the originally loaded input file; cloning
preserves that path. A user-preference menu should explicitly choose its own
persistence destination rather than rewriting authored project defaults.

## Binding names and equality

`input.canonical_binding(binding)` returns a validated canonical variant:
keyboard keys use uppercase mapping tokens (`ESCAPE`, `LEFT_CONTROL`, `0`, etc.),
mouse buttons use `LEFT`, `RIGHT`, `MIDDLE`, `SIDE`, `EXTRA`, `FORWARD`, or `BACK`,
and gamepad buttons retain Rune's `A`, `B`, `X`, `Y`, D-pad, bumper, trigger,
`BACK`, `START`, `GUIDE`, and thumb tokens. Keyboard `ESC`/`LEFT_CTRL` aliases and
case-insensitive key/button spellings normalize to their canonical form.
Unrelated variant fields are cleared; the controller index remains part of a
gamepad binding.

`input.binding_equal(a, b)` compares these canonical variants. Invalid bindings
never compare equal. This primitive supports game-specific conflict rules
without imposing them in the engine.

For native capture, `keyboard_key_name(rl.KeyboardKey)`,
`mouse_button_name(rl.MouseButton)`, and `gamepad_button_name(rl.GamepadButton)`
return tokens accepted by the existing mapping parsers. Keyboard capture supports
every named raylib key, including punctuation, modifiers, navigation and keypad
keys. Unknown codes and keyboard `KEY_NULL` return an empty string. Name and
canonical-binding strings borrow permanent literals or type metadata, with no
temporary-buffer lifetime or allocation; do not free them. Rebinding retains
its own copy in the input arena.

A modal UI should call `input.capture` every frame it owns gameplay input.
Rune's raw F3 gizmo shortcut respects console focus and the preceding frame's
capture before input sampling resets capture. Other raw raylib input remains
available; the application must gate its own raw shortcuts while capturing.
