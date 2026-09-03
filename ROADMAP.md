# Rune roadmap

Rune already supports the core code-first workflow: JSON projects, scenes and
prefabs; typed ECS components; registered Odin systems; 2D and 3D rendering;
input; audio; physics; hot reload; validation; and runnable example games.

## Near term

- Keep all examples and validators building through one repeatable command.
- Improve 3D rendering integration, material coverage and diagnostics.
- Expand runtime gizmos and debugging tools where they improve iteration.
- Split large ECS implementation files as responsibilities become stable.
- Improve error messages with precise source paths and JSON locations.

## Later

- Optional scene hierarchy and component inspector.
- Asset dependency inspection and build/export tooling.
- Broader 3D asset, animation and physics coverage.
- More focused documentation and example projects.

The editor remains optional. Odin code and readable project files must always
be sufficient to build a complete game.

