package r3d_bridge

import "core:math"
import "core:strings"
import "rune:assets"
import r3d "r3d:r3d"
import rl "vendor:raylib"

// Borrowed framebuffer-aligned textures. Color is premultiplied RGB plus alpha;
// emission is an optional additive radiance mask whose black pixels add no light.
// Raylib RenderTexture colors are display encoded by default. Set linear_color
// when both inputs already contain scene-linear color. Depth is never borrowed.
Scene_Color_Overlay :: struct {
	color, emission: rl.Texture2D,
	emission_energy: f32,
	linear_color: bool,
}

// Called once per valid scene draw, before R3D_Begin. Finish all raylib texture
// and 3D modes before returning. Textures remain caller-owned through this draw.
Scene_Overlay_Draw :: proc(data: rawptr, framebuffer: [2]i32) -> Scene_Color_Overlay

@(private)
scene_overlay_texture_valid :: proc(texture: rl.Texture2D) -> bool {
	return texture.id!=0 && texture.width>0 && texture.height>0
}

// Map native scene UV to the visible framebuffer, accounting for R3D's integer
// viewport rounding and top-left public/bottom-left texture coordinate systems.
@(private)
scene_overlay_uv_transform :: proc(framebuffer: [2]i32, viewport: rl.Rectangle, cropped: bool) -> [4]f32 {
	if !cropped || framebuffer[0]<=0 || framebuffer[1]<=0 {return {1,1,0,0}}
	x,y:=i32(viewport.x+0.5),i32(viewport.y+0.5)
	w,h:=i32(viewport.width+0.5),i32(viewport.height+0.5)
	return {f32(w)/f32(framebuffer[0]),f32(h)/f32(framebuffer[1]),f32(x)/f32(framebuffer[0]),f32(framebuffer[1]-y-h)/f32(framebuffer[1])}
}

@(private)
prepare_scene_overlay :: proc(ctx: ^Context, manager: ^assets.Asset_Manager, settings: Scene3D_Settings, viewport: rl.Rectangle, cropped: bool) -> bool {
	if settings.scene_overlay==nil {return false}
	framebuffer:=[2]i32{rl.GetRenderWidth(),rl.GetRenderHeight()}
	if framebuffer[0]<=0 || framebuffer[1]<=0 {return false}
	layer:=settings.scene_overlay(settings.scene_overlay_data,framebuffer)
	if !scene_overlay_texture_valid(layer.color) {return false}
	if !ctx.scene_overlay_attempted {
		ctx.scene_overlay_attempted=true
		source :: #load("scene_overlay.glsl",string)
		ctx.scene_overlay_shader=r3d.LoadScreenShaderFromMemory(strings.clone_to_cstring(source,context.temp_allocator))
		if ctx.scene_overlay_shader==nil {
			assets.report_failure(manager,{kind=.PostProcessing,field="Scene3D_Settings.scene_overlay",detail="could not load scene color overlay shader"})
		} else {assets.resolve_asset_failure(manager,"","Scene3D_Settings.scene_overlay","")}
	}
	if ctx.scene_overlay_shader==nil {return false}
	uv:=scene_overlay_uv_transform(framebuffer,viewport,cropped)
	emission:=layer.emission
	energy:=layer.emission_energy
	if !scene_overlay_texture_valid(emission) || math.is_nan(energy) || math.is_inf(energy) || energy<=0 {
		// Keep the sampler valid even when the shader's emission branch is disabled.
		emission=layer.color; energy=0
	}
	linear:=i32(1) if layer.linear_color else i32(0)
	r3d.SetScreenShaderSampler(ctx.scene_overlay_shader,"u_overlay_color",layer.color)
	r3d.SetScreenShaderSampler(ctx.scene_overlay_shader,"u_overlay_emission",emission)
	r3d.SetScreenShaderUniform(ctx.scene_overlay_shader,"u_overlay_uv",&uv)
	r3d.SetScreenShaderUniform(ctx.scene_overlay_shader,"u_overlay_energy",&energy)
	r3d.SetScreenShaderUniform(ctx.scene_overlay_shader,"u_overlay_linear",&linear)
	return true
}
