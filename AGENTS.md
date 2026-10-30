# Rune agent guidance

For building or modifying games with Rune, use the repository's
[Rune game development skill](.agents/skills/rune-game-development/SKILL.md)
and the reference notes relevant to the task. For Rune tester reports,
regressions, and dependency issues, use the
[Rune bug triage skill](.agents/skills/rune-bug-triage/SKILL.md).
Repository skill copies are canonical; personal installations are not required
to work on Rune.

Use `tools/odin.bat`, `tools/odin.sh`, or `tools/odin.ps1` for manual compiler
invocations to share the compile lock. On Windows, `-linker:msvc` also discovers
a complete installed toolset through `tools/find_msvc.bat`; keep this discovery
in Rune rather than copying it into games.

Scene documents are the source of truth for authored levels. Game level editors
own creating and saving them; Rune owns validating, loading, and instantiating
them. Keep scene export APIs and console commands out of the engine. Component
serialization, inspection, and checkpoint saves support their documented runtime
uses without making a World the authoring source. See the
[scene authoring boundary](README.md#scene-authoring-boundary).

Keep this guidance, the relevant skills, and affected reference notes current in
the same change when relevant code or API contracts, ownership or coordinate
conventions, dependency pins or native artifacts, or build/test workflows change.
Also update them when a verified reusable finding adds knowledge or invalidates existing
advice. Retire stale claims, cite current source/documentation paths, and record
the actual validation context and limits. Do not add unverified claims or task
logs.

When gameplay APIs, component/schema defaults, lifecycle/input timing, resource
ownership, project creation/builds, or the recommended examples change, update
the game-development skill and affected notes in that same change. Read only
the references needed for the task rather than every skill or guide.

After updating either repository skill or its notes, synchronize its
corresponding installed personal copy when present. Keep repository guidance
portable and independent of machine-specific paths.
