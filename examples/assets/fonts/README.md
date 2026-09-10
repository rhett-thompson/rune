# Shared example font

The examples use **Inter**, by Rasmus Andersson and the Inter Project Authors.
The unmodified upright variable TrueType font and its SIL Open Font License 1.1
were downloaded from the official Google Fonts repository on 2026-09-10:

- Font: https://github.com/google/fonts/blob/main/ofl/inter/Inter%5Bopsz,wght%5D.ttf
- License: https://github.com/google/fonts/blob/main/ofl/inter/OFL.txt
- Upstream: https://github.com/rsms/inter

`Inter.ttf` SHA-256:
`29160a80ff49ddcab2c97711247e08b1fab27a484a329ce8b813d820dc559031`

The variable font uses its default upright regular instance in raylib.
Keep `OFL.txt` with the font when distributing examples.

## Changing the examples' font

All examples with text share this file. Replacing `Inter.ttf` with another
TrueType font at the same path changes the HUDs, scene text, and Clay menu
together; update the license and attribution when doing so. With texture hot
reload enabled, the running example refreshes the font automatically.

If changing the filename instead, update `FONT_PATH` in
`../../shared/text/text.odin` and the `TextRenderer.font` fields in the
`tilemap_2d` and `physics_platformer_2d` scenes.

New example code imports `example_text "../shared/text"` and calls
`example_text.init(&game.assets)` after `rune.init`. The engine owns the font
and releases it during `rune.shutdown`. Use `example_text.draw` and
`example_text.measure` together so centering uses the selected font's metrics.
Clay contexts borrow `example_text.font()` and refresh it with `ui.set_font`
before layout. The helper supports one example engine per process.

Rune loads scalable fonts into a 64-pixel atlas with bilinear filtering;
bitmap fonts retain their pixel filtering. The developer console retains its
own built-in font.
