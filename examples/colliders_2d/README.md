# 2D collider playground

A small scene demonstrating a capsule player, a horizontal capsule platform,
a capsule sensor, and independently offset box/circle colliders. Green outlines
show collision geometry; white crosses mark entity origins.

```powershell
odin build examples/colliders_2d -collection:rune=rune -out:build/colliders_2d.exe
./build/colliders_2d.exe
```

On Linux, omit `.exe` from both paths. Move with **A/D** and jump with **Space**.
The orange ray checks solid colliders; entering the gold sensor increments the
counter. Gameplay is ordinary Odin code in `main.odin`.

The player's transform is at its feet, while its capsule has an offset of
`[0, -32]`. Its visible body consists of simple child shapes. This makes it easy
to see what moves when editing only collision geometry.

Open the console with backtick, or use `tools/console.ps1` with an opt-in inbox:

```text
pause
inspect player CapsuleCollider2D
set player CapsuleCollider2D.offset [20,-32]
set player CapsuleCollider2D.axis "horizontal"
step 1
reload
resume
```

Runtime edits rebuild the native body and refresh its gizmo without saving the
scene. Edit `scenes/main.scene.json` to persist changes.

See [physics authoring and queries](../../docs/physics.md).
