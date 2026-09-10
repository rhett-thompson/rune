# Checkpoint Saves

A two-room demo of [Rune checkpoint saves](../../docs/save-load.md). Save your
position, health, opened chests, dropped coins, and progress in both rooms.

```powershell
odin run examples/save_load_2d -collection:rune=rune
```

| Control | Action |
| --- | --- |
| WASD | Move the player square. |
| H | Lose 10 health. |
| E | Collect the current room's chest for 10 coins. |
| Space | Spawn a persistent dropped coin. |
| Tab | Visit the other room. Each room retains its player state. |
| F5 | Save the checkpoint slot. |
| F9 | Load that slot. |
| P | Pause. Save/load and room switching still work. |

Collect a chest, drop a coin, and press F5. Move and lose health, then press F9.
The earlier position/health and dropped coin return; the collected chest stays
gone. Visit both rooms and save, then restart the demo and press F9 to resume.

The game ID is `rune-checkpoint-demo`. Saves live in its `saves` subdirectory under
the OS user-data directory. A first run has no checkpoint until F5 is pressed.
The `checkpoint` and `restore` console commands queue the same operations;
completion failures appear in the on-screen status and developer console.

`main.odin` registers Transform and Health for persistence, tracks spawned coins,
and saves shared progress from a world resource through `before_save`. Both
`start` and `on_save_restored` initialize that resource from save globals.
Scene hot reload is disabled in this demo.
