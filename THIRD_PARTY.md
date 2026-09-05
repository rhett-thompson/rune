# Third-party code and example assets

Rune's own code license is undecided. No root engine license has been added.
Choosing it does not establish a license for separately sourced example assets.

## Runtime dependencies

| Dependency | Location / evidence | Release follow-up |
| --- | --- | --- |
| r3d Odin bindings and bundled native libraries | Pinned Git submodule in `third_party/r3d-odin`; [bundled license](third_party/r3d-odin/LICENSE) | Preserve that notice. Review the notices required by the bundled r3d, Assimp, and other native libraries before distributing binary packages. |
| raylib | `vendor:raylib` in the selected Odin toolchain | Preserve the upstream notices appropriate to the toolchain and any distributed binaries. |
| Box2D and Box3D | `vendor:box2d` and `vendor:box3d` in the selected Odin toolchain | Review the selected toolchain's bundled notices when preparing binary packages. |

The pinned binding's license file documents that binding; it is not a substitute
for reviewing every library shipped inside a prebuilt native archive.

## Example assets

[docs/asset_credits.json](docs/asset_credits.json) records the current asset groups
and the evidence still needed. The Brackeys pack includes its own
[license and credits](<examples/assets/brackeys_platformer_assets/LICENSE & CREDITS.txt>),
which declares CC0 and names the original contributors. Preserve that file.

The remaining groups currently lack source/license evidence in this repository:

- dungeon crawler and sprite-scene art and audio;
- arcade game sounds and music, including shared music;
- the `mecha.png` bitmap font;
- the example bell sound;
- example models and crate material textures.

For each group, record the original source URL, creator, license text or a
durable copy of the grant, and any modifications. If an asset was made specifically
for Rune, record that authorship instead of guessing an external source.
Resolve or replace these assets before including them in a public release.
