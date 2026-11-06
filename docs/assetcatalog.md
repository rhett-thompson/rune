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

This package does not modify engine loading, authored JSON, cache keys, hot
reload, or filesystem access. Existing games need no configuration changes.
Normal asset and scene hot reload continues to watch the resolved filenames;
opening or replacing a catalog is an explicit game-code operation.

To use the same file for publishing, include it and its resource folders in
`publish.json`'s `content`, set `prune.enabled` to true, and list `assets.json` in
`prune.manifests`. The publisher treats the values in `assets` and `directories`
as roots and follows its existing scene/prefab/model dependency traversal. Its
optional `roots`, `dependencies`, and `inputs` fields keep their existing
publishing meaning. Asset IDs are not interpreted inside authored JSON.
