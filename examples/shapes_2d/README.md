# Shapes 2D

A texture-free scene demonstrating filled/outlined shapes, rotation and scaling,
entity activation, and timed destruction. The purple bar disappears after five
simulation seconds. The red rectangle starts disabled.

Open the console with backtick and try:

```text
disable group
enable group
enable hidden
pause
set temporary Lifetime.seconds 1
step 60
reload
```

Run `pause` before the purple bar expires to inspect or reset its lifetime.
Reload restores all authored entities and their activation settings.

See [the feature guide](../../docs/entity_features.md) for the Odin APIs and JSON fields.
