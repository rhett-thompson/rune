package assets

import "core:encoding/json"
import "core:math"
import "rune:jsonutil"
import rl "vendor:raylib"

// An absent procedural block leaves enabled false. All maps share a seamless
// UV-space height field; generated images are independent of a graphics context.
Procedural_Material :: struct {
	pattern: Procedural_Pattern,
	enabled: bool,
	resolution: i32,
	seed: i32,
	scale: i32,
	octaves: i32,
	persistence: f32,
	contrast: f32,
	color_a: [4]u8,
	color_b: [4]u8,
	bump_strength: f32,
	roughness_variation: f32,
}

Procedural_Pattern :: enum {noise, wood}

default_procedural_material :: proc() -> Procedural_Material {
	return {enabled = true, resolution = 256, seed = 0, scale = 8, octaves = 4,
		persistence = 0.5, contrast = 1, color_a = {65, 70, 76, 255},
		color_b = {190, 195, 200, 255}, bump_strength = 0.15, roughness_variation = 0.3}
}

// The returned field identifies an invalid setting for authoring diagnostics.
procedural_material_from_json :: proc(value: json.Value) -> (Procedural_Material, bool, string) {
	object, ok := value.(json.Object)
	if !ok {return {}, false, ""}
	p := default_procedural_material()
	for key, value in object {
		switch key {
		case "pattern":
			name, valid := value.(json.String)
			ok = valid && (name == "noise" || name == "wood")
			if name == "wood" {p.pattern = .wood}
		case "enabled":
			p.enabled, ok = value.(json.Boolean)
		case "color_a", "color_b":
			color: [4]u8
			ok = read_color(value, &color)
			if key == "color_a" {p.color_a = color} else {p.color_b = color}
		case "resolution", "seed", "scale", "octaves":
			n, number_ok := jsonutil.number(value)
			lo, hi: f32 = 0, 65535
			if key == "resolution" {lo, hi = 8, 1024}
			if key == "scale" {lo, hi = 1, 64}
			if key == "octaves" {lo, hi = 1, 6}
			ok = number_ok && n >= lo && n <= hi && n == math.floor(n)
			if ok {
				x := i32(n)
				switch key {
				case "resolution": p.resolution = x; ok = (x & (x - 1)) == 0
				case "seed": p.seed = x
				case "scale": p.scale = x
				case "octaves": p.octaves = x
				}
			}
		case "persistence", "contrast", "bump_strength", "roughness_variation":
			n, number_ok := jsonutil.number(value)
			lo, hi: f32 = 0, 1
			if key == "contrast" {lo, hi = 0.1, 8}
			if key == "bump_strength" {hi = 2}
			ok = number_ok && n >= lo && n <= hi
			switch key {
			case "persistence": p.persistence = n
			case "contrast": p.contrast = n
			case "bump_strength": p.bump_strength = n
			case "roughness_variation": p.roughness_variation = n
			}
		case: return {}, false, key
		}
		if !ok {return {}, false, key}
	}
	return p, true, ""
}

procedural_material_signature :: proc(seed: u64, p: Procedural_Material) -> u64 {
	// Hash fields separately: struct padding is not deterministic.
	h := hash_value(seed, p.enabled)
	h = hash_value(h, p.pattern)
	h = hash_value(h, p.resolution)
	h = hash_value(h, p.seed)
	h = hash_value(h, p.scale)
	h = hash_value(h, p.octaves)
	h = hash_value(h, p.persistence)
	h = hash_value(h, p.contrast)
	h = hash_value(h, p.color_a)
	h = hash_value(h, p.color_b)
	h = hash_value(h, p.bump_strength)
	return hash_value(h, p.roughness_variation)
}

// Integer lattice hash with explicit wrapping in unsigned arithmetic.
procedural_lattice :: proc(x, y, period, seed: i32) -> f32 {
	xw, yw := ((x % period) + period) % period, ((y % period) + period) % period
	h := u32(xw) * 374761393 + u32(yw) * 668265263 + u32(seed) * 1274126177
	h = (h ~ (h >> 13)) * 1274126177
	h = h ~ (h >> 16)
	return f32(h & 0x00ffffff) / 16777215.0
}

procedural_noise :: proc(u, v: f32, period, seed: i32) -> f32 {
	x, y := u * f32(period), v * f32(period)
	xi, yi := i32(math.floor(x)), i32(math.floor(y))
	tx, ty := x - f32(xi), y - f32(yi)
	// Quintic interpolation gives continuous slopes across lattice boundaries.
	tx, ty = tx*tx*tx*(tx*(tx*6-15)+10), ty*ty*ty*(ty*(ty*6-15)+10)
	a := procedural_lattice(xi, yi, period, seed)
	b := procedural_lattice(xi+1, yi, period, seed)
	c := procedural_lattice(xi, yi+1, period, seed)
	d := procedural_lattice(xi+1, yi+1, period, seed)
	return (a + (b-a)*tx)*(1-ty) + (c + (d-c)*tx)*ty
}

procedural_height :: proc(p: Procedural_Material, u, v: f32) -> f32 {
	total, weight, amplitude: f32 = 0, 0, 1
	period := p.scale
	for octave in 0 ..< p.octaves {
		// Omit detail finer than two texels to avoid baked-in aliasing.
		if octave > 0 && period > p.resolution / 2 {break}
		total += procedural_noise(u, v, period, p.seed + octave * 1013) * amplitude
		weight += amplitude
		amplitude *= p.persistence
		period *= 2
	}
	value := total / weight
	if p.pattern == .wood {
		// Integer grain bands warped by tileable noise remain periodic in U/V.
		grain := 0.5 + 0.5 * math.sin(2 * f32(math.PI) * (u * f32(p.scale) + value * 0.5))
		// Thin dark growth lines against broader, gently mottled light grain.
		value = (1 - math.pow(grain, 6)) * (0.85 + 0.15 * value)
	}
	return clamp((value - 0.5) * p.contrast + 0.5, 0, 1)
}

Procedural_Material_Images :: struct {albedo, normal, orm: rl.Image}

destroy_procedural_material_images :: proc(images: ^Procedural_Material_Images) {
	if images == nil {return}
	for image in ([3]rl.Image{images.albedo, images.normal, images.orm}) {
		if image.data != nil {rl.UnloadImage(image)}
	}
	images^ = {}
}

generate_procedural_material_images :: proc(p: Procedural_Material) -> (Procedural_Material_Images, bool) {
	// Guard the public Odin entry point as well as JSON parsing.
	if !p.enabled || (p.pattern != .noise && p.pattern != .wood) || p.resolution < 8 || p.resolution > 1024 ||
	   (p.resolution & (p.resolution-1)) != 0 || p.scale < 1 || p.scale > 64 ||
	   p.octaves < 1 || p.octaves > 6 || p.seed < 0 || p.seed > 65535 ||
	   !(p.persistence >= 0 && p.persistence <= 1) || !(p.contrast >= 0.1 && p.contrast <= 8) ||
	   !(p.bump_strength >= 0 && p.bump_strength <= 2) ||
	   !(p.roughness_variation >= 0 && p.roughness_variation <= 1) {return {}, false}
	n := int(p.resolution)
	heights := make([]f32, n*n)
	defer delete(heights)
	for y in 0 ..< n {for x in 0 ..< n {
		heights[y*n+x] = procedural_height(p, (f32(x)+0.5)/f32(n), (f32(y)+0.5)/f32(n))
	}}
	images := Procedural_Material_Images{
		albedo = rl.GenImageColor(p.resolution, p.resolution, rl.WHITE),
		normal = rl.GenImageColor(p.resolution, p.resolution, rl.WHITE),
		orm = rl.GenImageColor(p.resolution, p.resolution, rl.WHITE),
	}
	if images.albedo.data == nil || images.normal.data == nil || images.orm.data == nil {
		destroy_procedural_material_images(&images)
		return {}, false
	}
	albedo := ([^][4]u8)(images.albedo.data)[:n*n]
	normal := ([^][4]u8)(images.normal.data)[:n*n]
	orm := ([^][4]u8)(images.orm.data)[:n*n]
	for y in 0 ..< n {for x in 0 ..< n {
		i := y*n+x
		h := heights[i]
		for c in 0 ..< 4 {albedo[i][c] = u8(f32(p.color_a[c])*(1-h) + f32(p.color_b[c])*h + 0.5)}
		// Wrapped central differences keep the normal map tileable too.
		dx := (heights[y*n+(x+1)%n] - heights[y*n+(x+n-1)%n]) * f32(n) * p.bump_strength * 0.5
		dy := (heights[((y+1)%n)*n+x] - heights[((y+n-1)%n)*n+x]) * f32(n) * p.bump_strength * 0.5
		inv_length := 1 / math.sqrt(dx*dx + dy*dy + 1)
		normal[i] = {u8((-dx*inv_length*0.5+0.5)*255+0.5), u8((-dy*inv_length*0.5+0.5)*255+0.5), u8((inv_length*0.5+0.5)*255+0.5), 255}
		// White AO/metal channels preserve the material's scalar controls.
		orm[i] = {255, u8((1-p.roughness_variation*(1-h))*255+0.5), 255, 255}
	}}
	return images, true
}
