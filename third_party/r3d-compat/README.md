# R3D 0.11 binding corrections

Rune uses the official r3d-odin revision
`66315303455641dc4f097630c14d3adb56ba2a48`. The submodule URL and upstream commit
remain recorded in the parent repository. [bindings.patch](bindings.patch)
contains two corrections to the published bindings:

- The Windows foreign import names `assimp-vc143-mt.lib`, matching the library
  shipped at that revision.
- `ImportFlag` matches the native R3D 0.11 mask instead of the previous combined
  quality flag.

| Native flag | Bit position | Mask |
| --- | --- | --- |
| `RETAIN_MESH_DATA` | 0 | 1 |
| `RETAIN_MESH_NAMES` | 1 | 2 |
| `SMOOTH_NORMALS` | 2 | 4 |
| `OPTIMIZE_MESH` | 3 | 8 |
| `VALIDATE_DATA` | 4 | 16 |

`IMPORT_QUALITY` combines smooth normals, mesh optimization, and data validation
(`4 | 8 | 16`, mask `28`). Mesh data and names remain separate options.

After initializing the submodule, run `tools\prepare_r3d.bat` on Windows or
`sh tools/prepare_r3d.sh` on Linux from the Rune checkout. The helpers resolve
their engine directory independently of the calling directory. Launchers,
validation, and generated project build scripts run preparation automatically.
Manual Odin commands require preparation first.

Preparation accepts the exact revision in
[`sources.json`](../r3d-importer/sources.json), applies the recorded patch once,
and accepts later runs only when the complete tracked diff equals that patch.
Unrelated tracked or untracked changes are rejected. `--check` verifies a
pristine or already prepared dependency without applying anything.

Release exports archive the official commit, then apply the parent-owned patch.
[files.blobs](files.blobs) records the expected Git blob hashes of every prepared
dependency file. It verifies archives without Git metadata; the old hashes in
the patch identify pristine input. Export preparation uses LF files explicitly,
independent of Windows Git line-ending settings.

When changing the upstream pin or these corrections, regenerate the patch with
the preparation helper's canonical diff options: full binary hashes, three
context lines, Myers algorithm, indent heuristic enabled, zero inter-hunk
context, normal `a/` and `b/` prefixes, and an empty order file. Disable external
diffs, text conversion, relative paths, colors, renames, and blank-line prefix
suppression. Regenerate the blob manifest from the pinned tree plus the patch's
new blob hashes, retaining its revision header. Both metadata files are kept as
LF by the parent repository's `.gitattributes`. Rebuild the importer and run the
Windows/Linux checks before recording the upgrade as validated. Preserve the
dependency's existing license notices.
