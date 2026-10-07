package r3d_bridge

import "rune:assets"
import "rune:particles"
import r3d "r3d:r3d"
import rl "vendor:raylib"

Particle3D_Batch :: struct {
	// Borrowed only for this draw. Positions are in world space; size is diameter.
	particles: []particles.Particle3D,
	material: string,
}

// Submit small glowing spheres inside R3D's scene, with depth testing and HDR
// bloom. No per-particle entities, asset allocations, shadows, or depth writes.
draw_particles_3d :: proc(ctx: ^Context, manager: ^assets.Asset_Manager, batches: []Particle3D_Batch) {
	for batch in batches {
		if len(batch.particles)==0 {continue}
		base:=material_from_path(ctx,manager,batch.material,{255,255,255,255})
		base.transparencyMode=.ALPHA; base.blendMode=.ADDITIVE
		for p in batch.particles {
			size,color:=particles.appearance_3d(p)
			if size<=0 || color[3]==0 {continue}
			material:=base
			// Fade radiance too: additive blending need not honor alpha.
			opacity:=f32(color[3])/255
			for i in 0..<3 {
				material.albedo.color[i]=u8(f32(base.albedo.color[i])*f32(color[i])/255*opacity)
				material.emission.color[i]=u8(f32(base.emission.color[i])*f32(color[i])/255)
			}
			material.albedo.color[3]=255
			material.emission.energy*=opacity
			r3d.DrawMesh(ctx.sphere_no_shadow,material,rl.Vector3(p.position),size*0.5)
			ctx.frame_stats.prop_draws+=1
		}
	}
}
