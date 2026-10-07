# Console typography

The developer console embeds the unmodified Inter upright variable TrueType
font by Rasmus Andersson and the Inter Project Authors under the SIL Open Font
License 1.1. Keep `OFL.txt` with this source when distributing Rune.

This is the same font as `examples/assets/fonts/Inter.ttf`, with SHA-256
`29160a80ff49ddcab2c97711247e08b1fab27a484a329ce8b813d820dc559031`.
See that folder's README for upstream provenance.

The atlas is created lazily at 64 pixels with bilinear filtering. Games may
borrow a different UI font through `console.set_font`; the console owns and
releases only its embedded atlas.
