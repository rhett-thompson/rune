// Shared typography for the standalone examples. The engine owns the font.
package text

import "core:math"
import "rune:assets"
import rl "vendor:raylib"

FONT_PATH :: "../assets/fonts/Inter.ttf"
SPACING :: 0.0

@(private)
manager: ^assets.Asset_Manager

// Call after rune.init, with the final engine address. One example runs per process.
init :: proc(owner: ^assets.Asset_Manager) -> bool {
	manager = owner
	if manager == nil {return false}
	_, ok := assets.font(manager, FONT_PATH)
	return ok
}

// Fetch the current cached font so hot reload never leaves a stale borrowed atlas.
font :: proc() -> rl.Font {
	if manager != nil {
		loaded, ok := assets.font(manager, FONT_PATH)
		if ok {return loaded}
	}
	return rl.GetFontDefault()
}

draw :: proc(value: cstring, x, y, size: i32, color: rl.Color) {
	rl.DrawTextEx(font(), value, {f32(x), f32(y)}, f32(size), SPACING, color)
}

measure :: proc(value: cstring, size: i32) -> i32 {
	return i32(math.ceil(rl.MeasureTextEx(font(), value, f32(size), SPACING).x))
}
