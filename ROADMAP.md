# Rune roadmap

Rune already supports the core code-first workflow: JSON projects, scenes and
prefabs; typed ECS components; registered Odin systems; 2D and 3D rendering;
input; audio; physics; hot reload; validation; and runnable example games.

Scene documents remain the source of truth: game level editors own creating and
saving them, while Rune owns loading and instantiation. Scene export is outside
the engine's scope; see the [scene authoring boundary](README.md#scene-authoring-boundary).

## Near term

- Keep all examples and validators building through one repeatable command.
- Improve 3D rendering integration, material coverage and diagnostics.
- Expand runtime gizmos and debugging tools where they improve iteration.
- Split large ECS implementation files as responsibilities become stable.
- Improve error messages with precise source paths and JSON locations.
- Publish portable Windows AMD64 and Linux AMD64 games; see the
  [publishing plan](docs/publishing.md):
  - Available: executable-relative startup and resource helpers, plus an explicit
    player build profile in the Windows/Linux generated helpers.
  - Available: the [Rune Publish CLI](rune_publish/README.md), `publish.json`,
    complete configured content folders or opt-in dependency pruning, dry runs,
    staged validation, ZIP/tar.gz archives, file manifests, native dependency
    audits, and engine/toolchain notices. New projects include an empty
    `publish.assets.json` for code-loaded resources; pruning defaults to disabled.
  - Extend the existing OS user-data save workflow to general game settings,
    input bindings, and file logs with a stable game identity.
  - Qualify packages on fresh supported systems, the declared Linux ABI baseline,
    and target hardware; verify saves/settings across upgrades before claiming
    complete publishing coverage.
- Add manually authored off-mesh navigation links (`NavLink3D`):
  - Connect disconnected navmesh surfaces with start/end points, one-way or bidirectional travel, and configurable traversal cost.
  - Support enabling/disabling links at runtime and have path queries and agents replan when links change.
  - Expose a traversal handoff to game code without assuming a movement method; add runtime debug visualization and pathfinding tests.
  - Follow up with jump, ladder, elevator, moving-platform, and teleport traversal behaviors.
- Add seamless neighboring terrain tiles:
  - Define a terrain grid with matching tile sizes and sample spacing, and automatic neighbor connections.
  - Match border heights and calculate edge normals using neighboring samples.
  - Align texture coordinates and material weights across borders, with biome transition bands on the existing tiles.
  - Allow different eight-layer palettes per tile while sharing the materials used at each boundary.
  - Verify collision traversal, hot reload and four-way corners in a 2×2 terrain example.

## Later

- Expand the publishing dependency formats and package-size diagnostics supported
  by the existing opt-in asset pruning.
- Extend publishing with store uploads, installers, packed assets, and
  cross-compilation when the portable package workflow is established.
- Broader 3D asset, animation and physics coverage.
- More focused documentation and example projects.
- Expand terrain grids into large worlds with nearby-tile streaming, distance-based detail reduction, and seamless joins between different detail levels.
