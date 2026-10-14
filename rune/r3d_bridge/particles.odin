package r3d_bridge

import "rune:assets"
import "rune:particles"
import "core:math"
import "core:slice"
import r3d "r3d:r3d"
import rl "vendor:raylib"

Particle3D_Batch :: struct {
	// Borrowed only for this draw. Positions are in world space; size is diameter.
	particles: []particles.Particle3D,
	material: string,
	shape: Particle3D_Shape,
	blend: Particle3D_Blend,
}

Particle3D_Shape :: enum {Sphere, Billboard}
Particle3D_Blend :: enum {Additive, Alpha}

Particle_Billboard_Instance :: struct {
	position: rl.Vector3,
	scale: rl.Vector3,
	color: rl.Color,
	depth: f32,
}

Particle_Billboard_Batch :: struct {
	buffer: r3d.InstanceBuffer,
	instances: [dynamic]Particle_Billboard_Instance,
	positions, scales: [dynamic]rl.Vector3,
	colors: [dynamic]rl.Color,
}

Particle_Billboard_Renderer :: struct {
	// Distinct buffers preserve earlier submissions until R3D ends the scene.
	batches: [dynamic]Particle_Billboard_Batch,
	texture: rl.Texture2D,
}

// Default batches retain the small additive spheres used for glowing bursts.
// Soft billboards use persistent instancing buffers and the same lit HDR scene.
// Both shapes depth-test without shadows, particle entities, or depth writes.
draw_particles_3d :: proc(ctx: ^Context, manager: ^assets.Asset_Manager, batches: []Particle3D_Batch, camera: rl.Camera3D={}) {
	for batch, index in batches {
		if len(batch.particles)==0 {continue}
		base:=material_from_path(ctx,manager,batch.material,{255,255,255,255})
		base.transparencyMode=.ALPHA
		base.blendMode=.ADDITIVE if batch.blend==.Additive else .MIX
		if batch.shape==.Billboard {
			view:=camera
			if view.position==view.target {view=particle_billboard_camera(r3d.GetMatrixInvView())}
			draw_particle_billboards(ctx,batch,index,base,view)
			continue
		}
		for p in batch.particles {
			size,color:=particles.appearance_3d(p)
			if size<=0 || color[3]==0 {continue}
			material:=particle_sphere_material(base,color,batch.blend)
			r3d.DrawMesh(ctx.sphere_no_shadow,material,rl.Vector3(p.position),size*0.5)
			ctx.frame_stats.prop_draws+=1
		}
	}
}

particle_sphere_material :: proc(base: r3d.Material, color: [4]u8, blend: Particle3D_Blend) -> r3d.Material {
	material:=base
	// Preserve existing sphere radiance fades independently of blend alpha.
	opacity:=f32(color[3])/255 if blend==.Additive else f32(1)
	for i in 0..<3 {
		material.albedo.color[i]=u8(f32(base.albedo.color[i])*f32(color[i])/255*opacity)
		material.emission.color[i]=u8(f32(base.emission.color[i])*f32(color[i])/255)
	}
	material.albedo.color[3]=255 if blend==.Additive else u8(u32(base.albedo.color[3])*u32(color[3])/255)
	material.emission.energy*=opacity
	return material
}

particle_billboard_camera :: proc(inverse_view: rl.Matrix) -> rl.Camera3D {
	position:=rl.Vector3{inverse_view[0,3],inverse_view[1,3],inverse_view[2,3]}
	return {
		position=position,
		target=position-rl.Vector3{inverse_view[0,2],inverse_view[1,2],inverse_view[2,2]},
		up={inverse_view[0,1],inverse_view[1,1],inverse_view[2,1]},
	}
}

prepare_particle_billboards :: proc(state: ^Particle_Billboard_Batch, batch: Particle3D_Batch, camera: rl.Camera3D) {
	clear(&state.instances)
	reserve(&state.instances,len(batch.particles))
	forward:=camera.target-camera.position
	for p in batch.particles {
		valid:=p.lifetime>0
		for value in ([]f32{p.position[0],p.position[1],p.position[2],p.age,p.lifetime,p.start_size,p.end_size}) {
			if math.is_nan(value) || math.is_inf(value) {valid=false; break}
		}
		if !valid {continue}
		size,color:=particles.appearance_3d(p)
		if size<=0 || color[3]==0 {continue}
		// R3D's transparent additive mode uses SRC_ALPHA too, so retaining the
		// instance alpha fades both lit color and emission through the soft mask.
		delta:=p.position-camera.position
		append(&state.instances,Particle_Billboard_Instance{
			position=rl.Vector3(p.position),scale={size,size,size},color=rl.Color(color),
			depth=delta[0]*forward[0]+delta[1]*forward[1]+delta[2]*forward[2],
		})
	}
	// Standard alpha needs back-to-front ordering within the instanced draw.
	if batch.blend==.Alpha {
		slice.sort_by(state.instances[:],proc(a,b:Particle_Billboard_Instance)->bool {return a.depth>b.depth})
	}
	count:=len(state.instances)
	resize(&state.positions,count); resize(&state.scales,count); resize(&state.colors,count)
	for instance,i in state.instances {
		state.positions[i]=instance.position; state.scales[i]=instance.scale; state.colors[i]=instance.color
	}
}

draw_particle_billboards :: proc(ctx: ^Context, batch: Particle3D_Batch, index: int, source: r3d.Material, camera: rl.Camera3D) {
	material:=source
	state:=&ctx.particle_billboards
	if state.texture.id==0 {
		// White RGB avoids dark fringes with ordinary alpha blending. The radial
		// mask supplies the billboard shape; authored material color supplies tint.
		image:=rl.GenImageGradientRadial(64,64,0,rl.WHITE,{255,255,255,0})
		state.texture=rl.LoadTextureFromImage(image)
		rl.UnloadImage(image)
		if !rl.IsTextureValid(state.texture) {return}
		rl.GenTextureMipmaps(&state.texture)
		rl.SetTextureFilter(state.texture,.TRILINEAR)
		rl.SetTextureWrap(state.texture,.CLAMP)
	}
	if len(state.batches)<=index {resize(&state.batches,index+1)}
	data:=&state.batches[index]
	prepare_particle_billboards(data,batch,camera)
	count:=i32(len(data.instances))
	if count==0 {return}
	if data.buffer.capacity==0 {data.buffer=r3d.LoadInstanceBuffer(max(i32(64),count),{.POSITION,.SCALE,.COLOR})}
	else if data.buffer.capacity<count {r3d.ResizeInstanceBuffer(&data.buffer,max(count,data.buffer.capacity*2),false)}
	if data.buffer.capacity<count {return}
	r3d.UploadInstances(data.buffer,{.POSITION},0,count,raw_data(data.positions),true)
	r3d.UploadInstances(data.buffer,{.SCALE},0,count,raw_data(data.scales),true)
	r3d.UploadInstances(data.buffer,{.COLOR},0,count,raw_data(data.colors),true)
	material.albedo.texture=state.texture
	material.uvOffset={}; material.uvScale={1,1}
	material.alphaCutoff=0
	material.billboardMode=.FRONT; material.cullMode=.NONE
	material.depth.mode=.LESS
	r3d.DrawMeshInstanced(ctx.quad_no_shadow,material,data.buffer,count)
	ctx.frame_stats.prop_draws+=1; ctx.frame_stats.instanced_batches+=1
	ctx.frame_stats.prop_instances+=int(count); ctx.frame_stats.prop_draws_avoided+=int(count)-1
	ctx.frame_stats.instance_uploads+=3
}

release_particle_billboards :: proc(ctx: ^Context) {
	for &batch in ctx.particle_billboards.batches {
		if batch.buffer.capacity>0 {r3d.UnloadInstanceBuffer(batch.buffer)}
		delete(batch.instances); delete(batch.positions); delete(batch.scales); delete(batch.colors)
	}
	delete(ctx.particle_billboards.batches)
	if ctx.particle_billboards.texture.id!=0 {rl.UnloadTexture(ctx.particle_billboards.texture)}
	ctx.particle_billboards={}
}
