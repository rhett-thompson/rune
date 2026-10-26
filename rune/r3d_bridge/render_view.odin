package r3d_bridge

import "core:math"
import "rune:ecs"
import r3d "r3d:r3d"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

// A caller-owned offscreen view through the regular R3D geometry, lighting and
// HDR effect pipeline. Its result can join another scene before shared output.
Render_View3D :: struct {
	target: rl.RenderTexture2D,
	coverage_shader: rl.Shader,
	coverage_attempted: bool,
	depth_location: i32,
	valid: bool,
}

Render_View3D_Settings :: struct {
	camera: rl.Camera3D,
	post_processing: ecs.PostProcessing,
	ambient_color: rl.Color,
	ambient_energy: f32,
	// Existing lights are excluded by default. Explicit view lights borrow their
	// native handles, with enabled states restored when the view finishes.
	inherit_lights: bool,
	lights: []r3d.Light,
}

Render_View3D_Draw :: proc(ctx: ^Context, data: rawptr)

@(private)
Render_View_Light_State :: struct {
	light: r3d.Light,
	enabled: bool,
}

default_render_view_3d_settings :: proc(camera: rl.Camera3D) -> Render_View3D_Settings {
	profile:=ecs.default_post_processing()
	profile.anti_aliasing=.disabled
	return {camera=camera,post_processing=profile,ambient_color=rl.WHITE,ambient_energy=1}
}

@(private)
active_render_view_3d: bool

@(private)
RENDER_VIEW_COVERAGE_FRAGMENT :: `#version 330
in vec2 fragTexCoord;
uniform sampler2D texture0;
uniform sampler2D viewDepth;
out vec4 finalColor;
void main() {
    vec3 radiance=texture(texture0,fragTexCoord).rgb;
    float depth=texture(viewDepth,fragTexCoord).r;
    // Native scene color is already composited over black. Opaque depth gives
    // coverage; additive RGB outside that coverage remains additive after merge.
    float coverage=depth<1.0 ? 1.0 : 0.0;
    finalColor=vec4(radiance,coverage);
}`

@(private)
load_render_view_3d_target :: proc(width,height:i32) -> rl.RenderTexture2D {
	target:rl.RenderTexture2D
	target.id=rlgl.LoadFramebuffer()
	if target.id==0 {return {}}
	target.texture={id=rlgl.LoadTexture(nil,width,height,i32(rl.PixelFormat.UNCOMPRESSED_R16G16B16A16),1),width=width,height=height,mipmaps=1,format=.UNCOMPRESSED_R16G16B16A16}
	if target.texture.id==0 {rlgl.UnloadFramebuffer(target.id);return {}}
	rlgl.FramebufferAttach(target.id,target.texture.id,i32(rlgl.FramebufferAttachType.COLOR_CHANNEL0),i32(rlgl.FramebufferAttachTextureType.TEXTURE2D),0)
	if !rlgl.FramebufferComplete(target.id) {rl.UnloadRenderTexture(target);return {}}
	rl.SetTextureFilter(target.texture,.BILINEAR)
	rl.SetTextureWrap(target.texture,.CLAMP)
	return target
}

// Call outside an active R3D session, normally from scene_overlay before the
// world begins. Submit ordinary R3D draws in draw; do not begin/end another view.
// The HDR profile runs native SSAO/SSIL/SSGI/SSR, fog, DOF and optional bloom.
// Tone mapping, color grading, AA and grain remain in the final combined scene.
// Auto exposure has one native temporal history and is deliberately final-only.
// Opaque geometry and zero-alpha additive effects are supported. Ordinary alpha
// materials need an explicit coverage layer or the legacy color-overlay path.
render_view_3d :: proc(view:^Render_View3D,ctx:^Context,dimensions:[2]i32,settings:Render_View3D_Settings,draw:Render_View3D_Draw,data:rawptr=nil) -> Scene_Color_Overlay {
	if view==nil {return {}}
	view.valid=false
	if ctx==nil || !ctx.initialized || draw==nil || active_render_view_3d || dimensions[0]<=0 || dimensions[1]<=0 {return {}}
	if math.is_nan(settings.ambient_energy) || math.is_inf(settings.ambient_energy) || settings.ambient_energy<0 {return {}}
	if settings.post_processing.enabled && !ecs.post_processing_valid(settings.post_processing) {return {}}
	when !PRE_TRANSPARENCY_SHADERS_SUPPORTED {return {}}
	if view.target.texture.width!=dimensions[0] || view.target.texture.height!=dimensions[1] {
		if view.target.id!=0 {rl.UnloadRenderTexture(view.target)}
		view.target=load_render_view_3d_target(dimensions[0],dimensions[1])
	}
	if view.target.id==0 {return {}}
	if !view.coverage_attempted {
		view.coverage_attempted=true
		view.coverage_shader=rl.LoadShaderFromMemory(nil,RENDER_VIEW_COVERAGE_FRAGMENT)
		if view.coverage_shader.id==rlgl.GetShaderIdDefault() {view.coverage_shader={}}
		else {view.depth_location=rl.GetShaderLocation(view.coverage_shader,"viewDepth")}
	}
	if view.coverage_shader.id==0 {return {}}
	// Save explicit handles before the native hook can disable world lights.
	// Inherited views leave those lights alone, so their temporary enables need
	// restoration here too. Deduplicate before enabling any selected handle.
	light_states:=make([]Render_View_Light_State,len(settings.lights))
	defer delete(light_states)
	light_count:=0
	for light in settings.lights {
		if !r3d.IsLightValid(light) {continue}
		seen:=false
		for saved in light_states[:light_count] {if saved.light==light {seen=true;break}}
		if seen {continue}
		light_states[light_count]={light=light,enabled=r3d.IsLightEnabled(light)}
		light_count+=1
	}
	defer {
		for saved in light_states[:light_count] {
			if !r3d.IsLightValid(saved.light) {continue}
			if saved.enabled {r3d.EnableLight(saved.light)}
			else {r3d.DisableLight(saved.light)}
		}
	}
	rlgl.DrawRenderBatchActive()
	if !begin_linear_view_capture(settings.inherit_lights) {return {}}
	active_render_view_3d=true
	defer active_render_view_3d=false
	finished:=false
	defer if !finished {color,depth:rl.Texture2D; end_linear_view_capture(&color,&depth)}
	baseline:=r3d.GetEnvironment()^
	defer r3d.SetEnvironment(&baseline)
	profile:=settings.post_processing
	if !profile.enabled {profile=ecs.default_post_processing()}
	environment:=post_processing_environment(r3d.ENVIRONMENT_BASE,profile)
	environment.background={color=rl.BLACK,energy=0}
	environment.ambient={color=settings.ambient_color,energy=settings.ambient_energy}
	// An offscreen compositing view has clear pixels, not a world sky. Fog may
	// affect its surfaces without filling uncovered pixels with additive haze.
	environment.fog.skyAffect=0
	environment.volumetricFog.skyAffect=0
	environment.autoExposure.enabled=false
	r3d.SetEnvironment(&environment)
	for saved in light_states[:light_count] {r3d.EnableLight(saved.light)}
	// R3D retains its existing internal resolution between views. The capture is
	// resampled into this view's output size without per-frame target reallocations.
	r3d.BeginPro({camera=r3d.CameraFromRL(settings.camera),target=view.target})
	draw(ctx,data)
	r3d.End()
	color,depth:rl.Texture2D
	captured:=end_linear_view_capture(&color,&depth)
	finished=true
	if !captured || color.id==0 || depth.id==0 {return {}}
	rl.BeginTextureMode(view.target)
	rl.ClearBackground({0,0,0,0})
	rl.BeginShaderMode(view.coverage_shader)
	rl.SetShaderValueTexture(view.coverage_shader,view.depth_location,depth)
	rlgl.DisableColorBlend()
	rl.DrawTexturePro(color,{0,0,f32(color.width),-f32(color.height)},{0,0,f32(dimensions[0]),f32(dimensions[1])},{},0,rl.WHITE)
	rlgl.DrawRenderBatchActive()
	rlgl.EnableColorBlend()
	rl.EndShaderMode()
	rl.EndTextureMode()
	view.valid=true
	return {color=view.target.texture,linear_color=true}
}

destroy_render_view_3d :: proc(view:^Render_View3D) {
	if view==nil {return}
	if view.target.id!=0 {rl.UnloadRenderTexture(view.target)}
	if view.coverage_shader.id!=0 {rl.UnloadShader(view.coverage_shader)}
	view^={}
}

when !PRE_TRANSPARENCY_SHADERS_SUPPORTED {
	@(private)
	begin_linear_view_capture :: proc(inherit_lights:bool) -> bool {return false}
	@(private)
	end_linear_view_capture :: proc(color,depth:^rl.Texture2D) -> bool {return false}
}
