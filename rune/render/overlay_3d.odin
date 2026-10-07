package render

import rl "vendor:raylib"
import "vendor:raylib/rlgl"

// A transparent 3D layer with its own color/depth attachments. Call after the
// world/reference canvas has been presented, before drawing the HUD.
Overlay3D :: struct {
	target: rl.RenderTexture2D,
	active: bool,
	glow_shader: rl.Shader,
	glow_attempted: bool,
	glow_step,glow_strength: i32,
}

// Present an emission-only layer additively with a soft halo. Black geometry
// can write depth in the mask to occlude emitters without adding any light.
Overlay3D_Glow :: struct {strength, radius: f32}

@(private)
OVERLAY_GLOW_FRAGMENT :: `#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
uniform sampler2D texture0;
uniform vec2 glowStep;
uniform float glowStrength;
out vec4 finalColor;
void main() {
    const float w[5] = float[5](0.06136, 0.24477, 0.38774, 0.24477, 0.06136);
    vec3 glow = vec3(0.0);
    for (int y = -2; y <= 2; ++y)
        for (int x = -2; x <= 2; ++x) {
            vec2 uv = fragTexCoord + vec2(x,y)*glowStep;
            // Outside the layer is black, not a wrapped copy of the other edge.
            if (any(lessThan(uv,vec2(0.0))) || any(greaterThan(uv,vec2(1.0)))) continue;
            glow += texture(texture0,uv).rgb*w[x+2]*w[y+2];
        }
    finalColor = vec4(glow*glowStrength,1.0);
}`

// Raylib texture modes cannot be nested; reject overlapping overlay passes.
@(private)
active_overlay_3d: ^Overlay3D

begin_overlay_3d :: proc(layer: ^Overlay3D, camera: rl.Camera3D,
                         width: i32 = -1, height: i32 = -1) -> bool {
	width,height:=width,height
	if width==-1 {width=rl.GetRenderWidth()}
	if height==-1 {height=rl.GetRenderHeight()}
	if layer==nil || layer.active || active_overlay_3d!=nil || active_canvas_size[0]>0 || width<=0 || height<=0 {return false}
	if layer.target.texture.width!=width || layer.target.texture.height!=height {
		destroy_overlay_3d(layer)
		layer.target=rl.LoadRenderTexture(width,height)
		if !rl.IsRenderTextureValid(layer.target) {destroy_overlay_3d(layer); return false}
		rl.SetTextureFilter(layer.target.texture,.BILINEAR)
	}
	rl.BeginTextureMode(layer.target)
	rl.ClearBackground({0,0,0,0}) // Clears this layer's depth, preserving world depth.
	rl.BeginMode3D(camera)
	layer.active=true
	active_overlay_3d=layer
	return true
}

end_overlay_3d :: proc(layer: ^Overlay3D,
                       destination: rl.Rectangle = {}, glow: Overlay3D_Glow = {}) {
	if layer==nil || !layer.active || active_overlay_3d!=layer {return}
	rl.EndMode3D()
	rl.EndTextureMode()
	layer.active=false
	active_overlay_3d=nil
	destination:=destination
	if destination.width==0 && destination.height==0 {destination={0,0,f32(rl.GetScreenWidth()),f32(rl.GetScreenHeight())}}
	if glow.strength>0 {
		if !layer.glow_attempted {
			layer.glow_attempted=true
			layer.glow_shader=rl.LoadShaderFromMemory(nil,OVERLAY_GLOW_FRAGMENT)
			if layer.glow_shader.id==rlgl.GetShaderIdDefault() {layer.glow_shader={}}
			else {
				layer.glow_step=rl.GetShaderLocation(layer.glow_shader,"glowStep")
				layer.glow_strength=rl.GetShaderLocation(layer.glow_shader,"glowStrength")
			}
		}
		rl.BeginBlendMode(.ADDITIVE)
		if layer.glow_shader.id!=0 {
			step:=[2]f32{max(f32(0),glow.radius)*0.5/f32(layer.target.texture.width),max(f32(0),glow.radius)*0.5/f32(layer.target.texture.height)}
			strength:=glow.strength
			rl.SetShaderValue(layer.glow_shader,layer.glow_step,&step,.VEC2)
			rl.SetShaderValue(layer.glow_shader,layer.glow_strength,&strength,.FLOAT)
			rl.BeginShaderMode(layer.glow_shader)
		}
		rl.DrawTexturePro(layer.target.texture,{0,0,f32(layer.target.texture.width),-f32(layer.target.texture.height)},destination,{},0,rl.WHITE)
		if layer.glow_shader.id!=0 {rl.EndShaderMode()}
		rl.EndBlendMode()
		return
	}
	rl.DrawTexturePro(layer.target.texture,{0,0,f32(layer.target.texture.width),-f32(layer.target.texture.height)},destination,{},0,rl.WHITE)
}

destroy_overlay_3d :: proc(layer: ^Overlay3D) {
	if layer==nil {return}
	if layer.active {
		rl.EndMode3D()
		rl.EndTextureMode()
		if active_overlay_3d==layer {active_overlay_3d=nil}
	}
	if layer.target.id!=0 {rl.UnloadRenderTexture(layer.target)}
	if layer.glow_shader.id!=0 {rl.UnloadShader(layer.glow_shader)}
	layer^={}
}
