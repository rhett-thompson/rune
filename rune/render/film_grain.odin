package render

import "core:math"
import "core:strings"
import "rune:ecs"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

// A reusable shader for display-space 2D draws. The same GLSL kernel is used by
// the R3D FINAL pass; this adapter preserves texture/tint coverage alpha.
Film_Grain_Effect :: struct {
	shader: rl.Shader,
	parameters: i32,
	attempted, active: bool,
}

@(private)
active_film_grain: ^Film_Grain_Effect

film_grain_parameters :: proc(settings: ecs.Post_Film_Grain, seconds: f64, pixel_scale: f32=1) -> ([3]f32,bool) {
	if !settings.enabled || settings.intensity<=0 {return {},false}
	for value in ([4]f32{settings.intensity,settings.size,settings.speed,pixel_scale}) {
		if math.is_nan(value) || math.is_inf(value) {return {},false}
	}
	if settings.intensity>1 || settings.size<1 || settings.size>8 || settings.speed<0 || settings.speed>60 ||
		pixel_scale<=0 || math.is_nan(seconds) || math.is_inf(seconds) || seconds<0 {return {},false}
	// Bound before conversion to retain animation precision in long sessions.
	phase:=f32(math.mod(math.floor(seconds*f64(settings.speed)),f64(65536)))
	return {settings.intensity,settings.size/pixel_scale,phase},true
}

// Call outside another shader mode. Draws use physical framebuffer pixels;
// pixel_scale maps a reference renderer's pixel size to the current framebuffer.
// For a flattened frame, draw its texture between begin/end. Disabled/invalid
// settings return false without allocating; callers can draw normally instead.
begin_film_grain :: proc(effect: ^Film_Grain_Effect, settings: ecs.Post_Film_Grain, seconds: f64, pixel_scale: f32=1) -> bool {
	if effect==nil || effect.active || active_film_grain!=nil {return false}
	params,valid:=film_grain_parameters(settings,seconds,pixel_scale)
	if !valid {return false}
	if !effect.attempted {
		effect.attempted=true
		source:=strings.concatenate([]string{
			`#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
uniform sampler2D texture0;
out vec4 finalColor;
#define COLOR finalColor
#define PIXCOORD ivec2(gl_FragCoord.xy)
vec4 FetchColor(ivec2 pixel) { return texture(texture0, fragTexCoord) * fragColor; }
`,
			#load("../r3d_bridge/film_grain.glsl",string),
			"\nvoid main() { fragment(); }\n",
		},context.temp_allocator)
		effect.shader=rl.LoadShaderFromMemory(nil,strings.clone_to_cstring(source,context.temp_allocator))
		if effect.shader.id==rlgl.GetShaderIdDefault() {effect.shader={}}
		else {effect.parameters=rl.GetShaderLocation(effect.shader,"u_grain")}
	}
	if effect.shader.id==0 {return false}
	rl.SetShaderValue(effect.shader,effect.parameters,&params,.VEC3)
	rl.BeginShaderMode(effect.shader)
	effect.active=true
	active_film_grain=effect
	return true
}

end_film_grain :: proc(effect: ^Film_Grain_Effect) {
	if effect==nil || !effect.active || active_film_grain!=effect {return}
	rl.EndShaderMode()
	effect.active=false
	active_film_grain=nil
}

destroy_film_grain :: proc(effect: ^Film_Grain_Effect) {
	if effect==nil {return}
	end_film_grain(effect)
	if effect.shader.id!=0 {rl.UnloadShader(effect.shader)}
	effect^={}
}
