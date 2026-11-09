# Named asset paths

`rune:assetcatalog` is an explicit lookup table. Open it in game code and pass the
returned paths to Rune's existing scene, prefab, asset, audio, or file loaders:

```odin
import "rune:assetcatalog"

catalog, error := assetcatalog.open(game.project_directory) // assets.json
if error != "" {return}
defer assetcatalog.destroy(&catalog)

path, found := assetcatalog.load(&catalog, "model.door")
if !found {return}
// Pass path to the existing loader.
```

```json
{
  "version": 1,
  "assets": {"model.door": "assets/models/door.glb"},
  "directories": {"dir.levels": "assets/levels"}
}
```

`open(root, filename)` accepts an optional project-relative manifest filename.
`load` returns a project-relative path and a success flag; unknown keys fail.
Named directory children such as `dir.levels/next.level.json` are supported.
Paths and child names cannot use absolute paths or parent traversal. Lookup does
not require the target file to exist, which also permits generated output paths.

The catalog owns its parsed data until `destroy`. Each returned path is owned by
the allocator supplied to `load` (frame scratch by default). Use a lasting
allocator for retained paths and free those copies with that allocator. Share a
catalog by pointer and destroy its owner once, after users finish.
The error string from `open` is a borrowed diagnostic and does not need freeing.

Game code opens or replaces the catalog explicitly. Engine loaders and authored
JSON continue to use ordinary paths, and hot reload watches those resolved files.

Rune Publish reads the root `assets.json` and includes it in the package. Each
`assets` value selects a file, and each `directories` value selects an entire
directory tree. The publisher also follows recognized dependencies from selected
files. The optional `dependencies` and `inputs` fields let games declare custom
references and check the sources of a generated catalog. See the [publishing guide](publishing.md#content-and-output).
