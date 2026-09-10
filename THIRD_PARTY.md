# Third-party code and example assets

Rune's original code is licensed under the [zlib license](LICENSE).
Third-party code and separately sourced example assets retain their own licenses;
the root license does not replace their terms or establish missing asset permissions.

## Runtime dependencies

| Dependency | Location / evidence | Release follow-up |
| --- | --- | --- |
| Clay UI layout | Vendored v0.14 snapshot in `third_party/clay`; [source pin](third_party/clay/README.rune.md), [zlib license](third_party/clay/LICENSE.md) | Optional `rune:ui` dependency. Preserve the notice; bindings and prebuilt libraries are pinned together. |
| r3d Odin bindings and bundled native libraries | Pinned Git submodule in `third_party/r3d-odin`; [bundled license](third_party/r3d-odin/LICENSE) | Preserve that notice. Review the notices required by the bundled r3d, Assimp, and other native libraries before distributing binary packages. |
| raylib | `vendor:raylib` in the selected Odin toolchain | Preserve the upstream notices appropriate to the toolchain and any distributed binaries. |
| stb_image | `vendor:stb/image` in the selected Odin toolchain; used for precision-preserving PNG heightmap decoding | Preserve the license notice bundled in the toolchain's `vendor/stb/src/stb_image.h`. |
| Box2D and Box3D | `vendor:box2d` and `vendor:box3d` in the selected Odin toolchain | Review the selected toolchain's bundled notices when preparing binary packages. |

The pinned binding's license file documents that binding; it is not a substitute
for reviewing every library shipped inside a prebuilt native archive.

## Example assets

The examples' shared Inter font is distributed under the
[SIL Open Font License 1.1](examples/assets/fonts/OFL.txt). Preserve that license;
[font provenance and usage](examples/assets/fonts/README.md) record its source.

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
