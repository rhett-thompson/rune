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
- Add manually authored off-mesh navigation links (`NavLink3D`):
  - Connect disconnected navmesh surfaces with start/end points, one-way or bidirectional travel, and configurable traversal cost.
  - Support enabling/disabling links at runtime and have path queries and agents replan when links change.
  - Expose a traversal handoff to game code without assuming a movement method; add editor/debug visualization and pathfinding tests.
  - Follow up with jump, ladder, elevator, moving-platform, and teleport traversal behaviors.
- Add seamless neighboring terrain tiles:
  - Define a terrain grid with matching tile sizes and sample spacing, and automatic neighbor connections.
  - Match border heights and calculate edge normals using neighboring samples.
  - Align texture coordinates and material weights across borders, with biome transition bands on the existing tiles.
  - Allow different eight-layer palettes per tile while sharing the materials used at each boundary.
  - Verify collision traversal, hot reload and four-way corners in a 2×2 terrain example.

## Later

- Optional scene hierarchy and component inspector.
- Asset dependency inspection and build/export tooling.
- Broader 3D asset, animation and physics coverage.
- More focused documentation and example projects.
- Expand terrain grids into large worlds with nearby-tile streaming, distance-based detail reduction, and seamless joins between different detail levels.

The editor remains optional. Odin code and readable project files must always
be sufficient to build a complete game.

