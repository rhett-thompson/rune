package r3d_bridge

import "core:testing"
import "rune:ecs"
import r3d "r3d:r3d"
import rl "vendor:raylib"

@(test)
volumetric_fog_maps_every_field :: proc(t: ^testing.T) {
	value := ecs.default_post_processing()
	value.volumetric_fog = {
		enabled = true,
		scattering_density = 0.023,
		absorption_density = 0.047,
		scattering_color = {17, 39, 71, 129},
		anisotropy = -0.37,
		emission_color = {211, 181, 151, 101},
		emission_energy = 0.63,
		sky_affect = 0.27,
		length = 83,
		step_size = 0.42,
	}
	base := r3d.ENVIRONMENT_BASE
	base.background.color = {91, 72, 53, 34}
	base.background.energy = 3.7
	base.background.sky.texture = 23
	base.ambient.color = {27, 46, 65, 84}
	base.ambient.energy = 0.13
	env := post_processing_environment(base, value)
	fog := env.volumetricFog
	testing.expect(t, fog.enabled)
	testing.expect(t, fog.scatteringDensity == value.volumetric_fog.scattering_density)
	testing.expect(t, fog.absortionDensity == value.volumetric_fog.absorption_density)
	testing.expect(t, fog.scatteringColor == rl.Color{17, 39, 71, 129})
	testing.expect(t, fog.anisotropy == value.volumetric_fog.anisotropy)
	testing.expect(t, fog.emissionColor == rl.Color{211, 181, 151, 101})
	testing.expect(t, fog.emissionEnergy == value.volumetric_fog.emission_energy)
	testing.expect(t, fog.skyAffect == value.volumetric_fog.sky_affect)
	testing.expect(t, fog.length == value.volumetric_fog.length)
	testing.expect(t, fog.stepSize == value.volumetric_fog.step_size)
	testing.expect(t, env.background == base.background && env.ambient == base.ambient,
		"post-processing must preserve the active sky and ambient lighting")
	testing.expect(t, base.volumetricFog == r3d.ENVIRONMENT_BASE.volumetricFog,
		"mapping must not modify the captured baseline")
	value.volumetric_fog.enabled = false
	disabled := post_processing_environment(env, value).volumetricFog
	testing.expect(t, !disabled.enabled && disabled.scatteringDensity == fog.scatteringDensity && disabled.emissionEnergy == fog.emissionEnergy,
		"disabling native fog retains its authored parameters")
}

@(test)
volumetric_fog_defaults_match_native_base :: proc(t: ^testing.T) {
	value := ecs.default_post_processing()
	env := post_processing_environment(r3d.ENVIRONMENT_BASE, value)
	testing.expect(t, env.volumetricFog == r3d.ENVIRONMENT_BASE.volumetricFog,
		"Rune defaults must preserve the r3d disabled baseline")
}
