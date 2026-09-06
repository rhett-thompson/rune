package render

import "rune:assets"
import "rune:ecs"
import "rune:particles"
import rl "vendor:raylib"

// Called inside the active Camera2D and the ordinary sorted 2D draw pipeline.
draw_particles_2d :: proc(world: ^ecs.World, manager: ^assets.Asset_Manager, entity: ecs.Entity) {
	emitter, found := ecs.get_particle_emitter_2d(world, entity)
	if !found {return}
	state := world.particle_states_2d[entity]
	if len(state.particles) == 0 {return}
	texture: rl.Texture2D
	textured := emitter.texture != ""
	if textured {texture, _ = assets.texture(manager, emitter.texture, "", "ParticleEmitter2D.texture")}
	if emitter.additive {rl.BeginBlendMode(.ADDITIVE)}
	defer if emitter.additive {rl.EndBlendMode()}
	for particle in state.particles {
		size, color := particles.appearance(particle)
		if size <= 0 || color[3] == 0 {continue}
		tint := rl.Color{color[0], color[1], color[2], color[3]}
		if textured {
			rl.DrawTexturePro(texture, {0, 0, f32(texture.width), f32(texture.height)},
				{particle.position[0], particle.position[1], size, size}, {size / 2, size / 2}, 0, tint)
		} else {
			rl.DrawCircleV(particle.position, size / 2, tint)
		}
	}
}
