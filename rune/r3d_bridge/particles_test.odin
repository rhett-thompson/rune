package r3d_bridge

import "core:math"
import "core:testing"
import "rune:particles"
import r3d "r3d:r3d"
import rl "vendor:raylib"

@(test)
particle_default_spheres_preserve_additive_radiance_fading :: proc(t: ^testing.T) {
	batch:Particle3D_Batch
	testing.expect(t,batch.shape==.Sphere && batch.blend==.Additive)
	base:=r3d.Material{albedo={color={80,120,200,42}},emission={color={255,128,60,255},energy=8}}
	faded:=particle_sphere_material(base,{128,220,255,128},batch.blend)
	testing.expect(t,faded.albedo.color==rl.Color{20,51,100,255})
	testing.expect(t,faded.emission.color==rl.Color{128,110,60,255})
	testing.expect(t,abs(faded.emission.energy-f32(4.015686))<0.00001,"existing sphere burst alpha still fades HDR emission")
	alpha:=particle_sphere_material(base,{128,220,255,128},.Alpha)
	testing.expect(t,alpha.albedo.color==rl.Color{40,103,200,21} && alpha.emission.energy==8,"alpha blending retains full radiance and carries opacity in alpha")
}

@(test)
particle_batches_override_emission_without_changing_authored_material :: proc(t: ^testing.T) {
	base:=r3d.Material{albedo={color={80,120,200,42}},emission={color={255,128,60,255},energy=8}}
	default_material:=particle_batch_material(base,{})
	testing.expect(t,default_material.emission.energy==8,"zero-valued batches preserve authored emission for existing bursts")
	disabled:=particle_batch_material(base,{emission_energy=3})
	testing.expect(t,disabled.emission.energy==8,"supplying energy alone does not enable the override")
	for shape in Particle3D_Shape {
		batch:=Particle3D_Batch{shape=shape,emission_energy=2.5,emission_energy_override=true}
		material:=particle_batch_material(base,batch)
		testing.expect(t,material.emission.energy==2.5,"both particle shapes accept absolute emission energy")
		testing.expect(t,material.emission.color==base.emission.color && material.albedo.color==base.albedo.color,"overrides retain authored colors")
		faded:=particle_sphere_material(material,{255,255,255,128},.Additive)
		testing.expect(t,abs(faded.emission.energy-f32(2.5*128/255))<0.00001,"sphere lifetime fades still apply after the override")
	}
	testing.expect(t,base.emission.energy==8,"batch overrides never change the cached material or other effects")
}

@(test)
particle_emission_override_accepts_zero_and_rejects_nonfinite_energy :: proc(t: ^testing.T) {
	base:=r3d.Material{emission={energy=8}}
	for energy in ([3]f32{0,-1,-100}) {
		material:=particle_batch_material(base,{emission_energy=energy,emission_energy_override=true})
		testing.expect(t,material.emission.energy==0,"zero disables emission and negative energies clamp to zero")
	}
	for energy in ([3]f32{math.nan_f32(),math.inf_f32(1),math.inf_f32(-1)}) {
		material:=particle_batch_material(base,{emission_energy=energy,emission_energy_override=true})
		testing.expect(t,material.emission.energy==8,"invalid override values preserve the authored energy")
	}
}

@(test)
particle_billboard_optional_camera_matches_native_view :: proc(t: ^testing.T) {
	position:=rl.Vector3{4,2,7}
	target:=rl.Vector3{-2,5,-8}
	view:=rl.MatrixLookAt(position,target,{0,1,0})
	camera:=particle_billboard_camera(rl.MatrixInvert(view))
	testing.expect(t,rl.Vector3Distance(camera.position,position)<0.00001)
	testing.expect(t,rl.Vector3Distance(rl.Vector3Normalize(camera.target-camera.position),rl.Vector3Normalize(target-position))<0.00001,"three-argument draws recover the active native view for ordering")
}

@(test)
particle_billboards_sort_alpha_by_camera_depth_and_preserve_input :: proc(t: ^testing.T) {
	state:Particle_Billboard_Batch
	defer {delete(state.instances); delete(state.positions); delete(state.scales); delete(state.colors)}
	live:=[3]particles.Particle3D{
		{position={2,0,0},lifetime=2,start_size=0.1,end_size=0.1,start_color={255,255,255,64},end_color={255,255,255,64}},
		{position={0,0,-100},lifetime=2,start_size=0.2,end_size=0.2,start_color={255,255,255,96},end_color={255,255,255,96}},
		{position={8,0,0},lifetime=2,start_size=0.3,end_size=0.3,start_color={255,255,255,128},end_color={255,255,255,128}},
	}
	original:=live
	batch:=Particle3D_Batch{particles=live[:],shape=.Billboard,blend=.Alpha}
	prepare_particle_billboards(&state,batch,{target={1,0,0}})
	testing.expect(t,len(state.instances)==3)
	testing.expect(t,state.positions[0]==rl.Vector3{8,0,0} && state.positions[1]==rl.Vector3{2,0,0},"alpha uses camera depth rather than distance from the camera")
	testing.expect(t,state.colors[0].a==128 && state.scales[0].x==0.3,"sorting preserves each particle's alpha and size")
	for p,i in live {testing.expect(t,p==original[i],"render preparation cannot reorder or advance game-owned particles")}
	prepare_particle_billboards(&state,batch,{target={0,0,-1}})
	testing.expect(t,state.positions[0]==rl.Vector3{0,0,-100},"turning the camera updates alpha ordering")
}

@(test)
particle_billboards_skip_invisible_particles_and_reuse_storage :: proc(t: ^testing.T) {
	state:Particle_Billboard_Batch
	defer {delete(state.instances); delete(state.positions); delete(state.scales); delete(state.colors)}
	live:=[4]particles.Particle3D{
		{position={0,0,-2},lifetime=2,start_size=0.2,end_size=0.2,start_color={255,255,255,120},end_color={255,255,255,120}},
		{position={0,0,-3},lifetime=2,start_size=0.2,end_size=0.2,start_color={255,255,255,0},end_color={255,255,255,0}},
		{position={0,0,-4},lifetime=2,start_size=0,end_size=0,start_color={255,255,255,120},end_color={255,255,255,120}},
		{position={0,0,-5},lifetime=0,start_size=0.2,end_size=0.2,start_color={255,255,255,120},end_color={255,255,255,120}},
	}
	batch:=Particle3D_Batch{particles=live[:],shape=.Billboard,blend=.Alpha}
	prepare_particle_billboards(&state,batch,{target={0,0,-1}})
	testing.expect(t,len(state.instances)==1,"zero alpha, zero size, and invalid lifetimes submit no billboard")
	instances,positions,scales,colors:=raw_data(state.instances),raw_data(state.positions),raw_data(state.scales),raw_data(state.colors)
	for _ in 0..<100 {prepare_particle_billboards(&state,batch,{target={0,0,-1}})}
	testing.expect(t,instances==raw_data(state.instances) && positions==raw_data(state.positions) && scales==raw_data(state.scales) && colors==raw_data(state.colors),"repeated draws reuse all CPU storage")
	prepare_particle_billboards(&state,{},{})
	testing.expect(t,len(state.positions)==0 && len(state.scales)==0 && len(state.colors)==0,"empty batches retain no stale instances")
}

@(test)
particle_billboards_radial_mask_has_soft_white_alpha_edges :: proc(t: ^testing.T) {
	image:=rl.GenImageGradientRadial(64,64,0,rl.WHITE,{255,255,255,0})
	defer rl.UnloadImage(image)
	center:=rl.GetImageColor(image,32,32)
	middle:=rl.GetImageColor(image,48,32)
	edge:=rl.GetImageColor(image,63,0)
	testing.expect(t,center.a>240 && middle.a>0 && middle.a<center.a && edge.a==0,"the generated mask fades smoothly to transparent outside its round footprint")
	testing.expect(t,edge.r==255 && edge.g==255 && edge.b==255,"transparent borders retain white RGB to avoid filtering dark fringes")
}
