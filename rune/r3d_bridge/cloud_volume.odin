package r3d_bridge

import "core:math"
import "core:strings"
import "rune:assets"
import "rune:ecs"
import r3d "r3d:r3d"
import rl "vendor:raylib"

Cloud_Volume_Renderer :: struct {
	shader: ^r3d.SurfaceShader,
	noise: rl.Texture2D,
	aliases: map[ecs.Entity]^r3d.SurfaceShader,
	generation: u32,
	attempted: bool,
	camera: rl.Camera3D,
	light: [3]f32,
}

release_cloud_volumes :: proc(ctx: ^Context) {
	c:=&ctx.cloud_volumes
	for _,alias in c.aliases {r3d.UnloadSurfaceShader(alias)}
	delete(c.aliases)
	if c.shader!=nil {r3d.UnloadSurfaceShader(c.shader)}
	if c.noise.id!=0 {rl.UnloadTexture(c.noise)}
	c^={}
}

// Reproducible coherent 3D noise, stored as a small slice atlas. The wrap
// border on each slice prevents filtering from bleeding into adjacent slices.
cloud_noise_hash :: proc(x,y,z: int) -> f32 {
	v:=u32(x%4)*73856093 ~ u32(y%4)*19349663 ~ u32(z%4)*83492791 ~ 0x9e3779b9
	v = v ~ (v>>16); v *= 0x7feb352d; v = v ~ (v>>15); v *= 0x846ca68b; v = v ~ (v>>16)
	return f32(v&0xffff)/65535
}

cloud_noise_value :: proc(x,y,z: int) -> f32 {
	p:=[3]f32{f32(x)/8,f32(y)/8,f32(z)/8}
	base:=[3]int{int(p[0]),int(p[1]),int(p[2])}
	f:=p-[3]f32{f32(base[0]),f32(base[1]),f32(base[2])}
	f=f*f*([3]f32{3,3,3}-f*2)
	value:f32
	for dz in 0..<2 {for dy in 0..<2 {for dx in 0..<2 {
		weight:=(f[0] if dx==1 else 1-f[0])*(f[1] if dy==1 else 1-f[1])*(f[2] if dz==1 else 1-f[2])
		value+=cloud_noise_hash(base[0]+dx,base[1]+dy,base[2]+dz)*weight
	}}}
	return value
}

load_cloud_noise :: proc() -> rl.Texture2D {
	image:=rl.GenImageColor(272,136,rl.WHITE)
	defer rl.UnloadImage(image)
	pixels:=(cast([^]rl.Color)image.data)[:272*136]
	for z in 0..<32 {for y in 0..<34 {for x in 0..<34 {
		value:=u8(clamp(cloud_noise_value((x+31)%32,(y+31)%32,z)*255,0,255))
		pixels[(z/8*34+y)*272+z%8*34+x]={value,value,value,255}
	}}}
	texture:=rl.LoadTextureFromImage(image)
	rl.SetTextureFilter(texture,.BILINEAR)
	return texture
}

prepare_cloud_volumes :: proc(ctx: ^Context, world: ^ecs.World, manager: ^assets.Asset_Manager, camera: rl.Camera3D) {
	if ctx.cloud_volumes_disabled {return}
	c:=&ctx.cloud_volumes
	if c.generation!=world.generation {
		for _,alias in c.aliases {r3d.UnloadSurfaceShader(alias)}
		clear(&c.aliases)
		c.generation=world.generation
	}
	removed:=make([dynamic]ecs.Entity,context.temp_allocator)
	for entity in c.aliases {if !ecs.has_component_data(world,entity,"CloudVolume") {append(&removed,entity)}}
	for entity in removed {r3d.UnloadSurfaceShader(c.aliases[entity]); delete_key(&c.aliases,entity)}
	entities:=ecs.entities_with_component(world,"CloudVolume")
	if len(entities)==0 {return}
	if !c.attempted {
		c.attempted=true
		c.aliases=make(map[ecs.Entity]^r3d.SurfaceShader)
		source::#load("cloud_volume.glsl",string)
		c.shader=r3d.LoadSurfaceShaderFromMemory(strings.clone_to_cstring(source,context.temp_allocator))
		if c.shader!=nil {c.noise=load_cloud_noise()}
		if c.shader==nil || c.noise.id==0 {
			assets.report_failure(manager,{kind=.PostProcessing,field="CloudVolume",detail="could not create volumetric cloud renderer"})
		} else {assets.resolve_asset_failure(manager,"","CloudVolume","")}
	}
	if c.shader==nil || c.noise.id==0 {return}
	c.camera=camera
	c.light={0.4,0.8,0.3}
	strongest:f32
	for entity,light in world.directional_lights {
		if !ecs.is_enabled(world,entity) || light.intensity<=strongest {continue}
		length:=math.sqrt(light.direction[0]*light.direction[0]+light.direction[1]*light.direction[1]+light.direction[2]*light.direction[2])
		if length>0 {c.light= -light.direction/length; strongest=light.intensity}
	}
	for entity in entities {if _,found:=c.aliases[entity]; !found {c.aliases[entity]=r3d.LoadSurfaceShaderAlias(c.shader)}}
}

draw_cloud_volume :: proc(ctx: ^Context, world: ^ecs.World, entity: ecs.Entity, transform: ecs.Transform,render_matrix:^rl.Matrix=nil) {
	if ctx.cloud_volumes_disabled {return}
	c:=&ctx.cloud_volumes
	shader,found:=c.aliases[entity]
	if !found || shader==nil {return}
	v,ok:=ecs.get(world,entity,ecs.CloudVolume)
	if !ok || v.density<=0 || !ecs.cloud_volume_valid(v) {return}
	for s in transform.scale {if s<=0 {return}}
	model:rl.Matrix
	if render_matrix!=nil {model=render_matrix^} else {model=detail_transform(transform)}
	// Surface uniform matrices use GLSL column-major storage, whereas raylib's
	// Matrix is row-major. Convert storage without changing the transform.
	inverse:=cast(matrix[4,4]f32)rl.MatrixInvert(model)
	forward:=rl.Vector3Normalize(c.camera.target-c.camera.position)
	color,shadow:[3]f32
	for i in 0..<3 {color[i]=math.pow(f32(v.color[i])/255,2.2); shadow[i]=math.pow(f32(v.shadow_color[i])/255,2.2)}
	settings:=[3]f32{v.density,v.noise_scale,v.coverage}
	r3d.SetSurfaceShaderUniform(shader,"u_inverse_model",&inverse)
	r3d.SetSurfaceShaderUniform(shader,"u_camera",&c.camera.position)
	r3d.SetSurfaceShaderUniform(shader,"u_forward",&forward)
	r3d.SetSurfaceShaderUniform(shader,"u_light",&c.light)
	r3d.SetSurfaceShaderUniform(shader,"u_color",&color)
	r3d.SetSurfaceShaderUniform(shader,"u_shadow",&shadow)
	r3d.SetSurfaceShaderUniform(shader,"u_offset",&v.noise_offset)
	r3d.SetSurfaceShaderUniform(shader,"u_settings",&settings)
	r3d.SetSurfaceShaderUniform(shader,"u_steps",&v.steps)
	r3d.SetSurfaceShaderSampler(shader,"u_noise",c.noise)
	r3d.SetSurfaceShaderSampler(shader,"u_depth",r3d.GetBufferDepth())
	material:=r3d.GetDefaultMaterial()
	material.shader=shader
	material.transparencyMode=.ALPHA
	material.cullMode=.FRONT
	material.alphaCutoff=0.001
	material.unlit=true
	if render_matrix!=nil {r3d.DrawMeshPro(ctx.cube_no_shadow,material,model)}
	else {r3d.DrawMeshEx(ctx.cube_no_shadow,material,transform.position,rotation_quaternion(transform),transform.scale)}
}
