package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "rune:assets"
import "rune:ecs"
import bridge "rune:r3d_bridge"
import r3d "r3d:r3d"
import rl "vendor:raylib"

parse :: proc(text: string) -> json.Value {
	value: json.Value
	assert(json.unmarshal(transmute([]u8)text, &value, allocator=context.temp_allocator) == nil)
	return value
}

sample_frame :: proc(ctx: ^bridge.Context, world: ^ecs.World, manager: ^assets.Asset_Manager) -> rl.Color {
	for _ in 0..<4 {
		rl.BeginDrawing()
		assert(bridge.draw_scene_ex(ctx, world, manager, {background_color=rl.BLACK}))
		rl.EndDrawing()
	}
	image := rl.LoadImageFromScreen()
	defer rl.UnloadImage(image)
	return rl.GetImageColor(image, 205, 120)
}

validate_runtime :: proc() {
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(320, 240, "Volumetric fog validation")
	defer rl.CloseWindow()
	ctx, ok := bridge.init(".", 320, 240)
	assert(ok)
	defer bridge.shutdown(&ctx)
	manager := assets.init(".")
	defer assets.shutdown(&manager)
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	world := ecs.init()
	defer ecs.destroy(&world)
	camera := ecs.create_entity(&world)
	assert(ecs.add(&world, &registry, camera, ecs.Transform{scale={1,1,1}}))
	assert(ecs.add_component(&world, &registry, camera, "Camera3D", parse(`{"active":true,"target":[0,0,-1],"fovy":60}`)))
	light := ecs.create_entity(&world)
	assert(ecs.add(&world, &registry, light, ecs.Transform{position={0,0,-8},scale={1,1,1}}))
	assert(ecs.add_component(&world, &registry, light, "DirectionalLight", parse(`{"direction":[0,0,1],"intensity":4,"range":80,"specular":0,"shadows":true,"shadow_overrides":{"softness":0,"update_mode":"continuous"}}`)))
	backdrop := ecs.create_entity(&world)
	// Give the fog a finite opaque depth without shadowing the light itself.
	assert(ecs.add(&world, &registry, backdrop, ecs.Transform{position={0,0,-24},scale={50,50,0.2}}))
	assert(ecs.add(&world, &registry, backdrop, ecs.MeshRenderer{primitive="cube",color={0,0,0,255}}))
	post := ecs.create_entity(&world)
	value := ecs.default_post_processing()
	value.anti_aliasing = .disabled
	value.volumetric_fog.scattering_density = 0.03
	value.volumetric_fog.absorption_density = 0.003
	value.volumetric_fog.anisotropy = 0.4
	value.volumetric_fog.sky_affect = 1
	value.volumetric_fog.length = 30
	value.volumetric_fog.step_size = 0.25
	assert(ecs.add(&world, &registry, post, value))
	baseline := r3d.GetEnvironment().volumetricFog
	// Keep a distinctive direct-r3d baseline to catch partial restoration.
	baseline.scatteringDensity = 0.071
	baseline.absortionDensity = 0.029
	baseline.scatteringColor = {17, 39, 71, 255}
	baseline.anisotropy = -0.2
	baseline.emissionColor = {211, 181, 151, 255}
	baseline.emissionEnergy = 0.37
	baseline.skyAffect = 0.19
	baseline.length = 73
	baseline.stepSize = 1.7
	baseline.enabled = false
	r3d.GetEnvironment().volumetricFog = baseline
	off := sample_frame(&ctx, &world, &manager)
	fmt.println("native fog disabled", off)
	assert(off.r < 5, "disabled native fog leaves the black scene unchanged")
	value.volumetric_fog.enabled = true
	assert(ecs.set(&world, post, value))
	on := sample_frame(&ctx, &world, &manager)
	fmt.println("lit scattering", on)
	assert(on.r > 30, "a real directional light scatters into otherwise black pixels")
	native_light, found := ctx.scene_lights[light]
	assert(found && r3d.IsLightEnabled(native_light) && r3d.IsShadowEnabled(native_light))
	blocker := ecs.create_entity(&world)
	assert(ecs.add(&world, &registry, blocker, ecs.Transform{position={0,0,-4},scale={30,30,0.2}}))
	assert(ecs.add(&world, &registry, blocker, ecs.MeshRenderer{primitive="cube",color={0,0,0,255},shadows=true}))
	blocked := sample_frame(&ctx, &world, &manager)
	fmt.println("opaque wall occlusion", blocked)
	assert(int(blocked.r) < int(on.r)-20, "opaque shadow-casting architecture blocks light scattering")
	assert(ecs.set_runtime_field(&world, &registry, light, "DirectionalLight", "shadows", json.Boolean(false)))
	unshadowed := sample_frame(&ctx, &world, &manager)
	fmt.println("opaque wall without light shadows", unshadowed)
	assert(int(blocked.r) < int(unshadowed.r)-20, "light shadows must suppress scattering in front of the same opaque wall")
	assert(ecs.set_runtime_field(&world, &registry, light, "DirectionalLight", "shadows", json.Boolean(true)))
	ecs.destroy_entity(&world, blocker)
	value.volumetric_fog.enabled = false
	assert(ecs.set(&world, post, value))
	assert(sample_frame(&ctx, &world, &manager).r < 5, "runtime native-fog toggle removes scattering")
	value.volumetric_fog.enabled = true
	assert(ecs.set(&world, post, value))
	assert(sample_frame(&ctx, &world, &manager).r > 30, "runtime native-fog toggle re-enables scattering")
	value.enabled = false
	assert(ecs.set(&world, post, value))
	r3d.GetEnvironment().background.energy = 4
	r3d.GetEnvironment().ambient.energy = 7
	bridge.apply_post_processing(&ctx, &world, camera)
	assert(r3d.GetEnvironment().volumetricFog == baseline, "disabling the selected profile restores every native-fog baseline field")
	assert(r3d.GetEnvironment().background.energy == 4 && r3d.GetEnvironment().ambient.energy == 7,
		"baseline restoration preserves current sky and ambient lighting")
	value.enabled = true
	assert(ecs.set(&world, post, value))
	bridge.apply_post_processing(&ctx, &world, camera)
	assert(ecs.remove_component(&world, post, "PostProcessing"))
	bridge.apply_post_processing(&ctx, &world, camera)
	assert(r3d.GetEnvironment().volumetricFog == baseline, "removing the selected profile restores the native-fog baseline")
	r3d.GetEnvironment().volumetricFog.length = 89
	bridge.apply_post_processing(&ctx, &world, camera)
	assert(r3d.GetEnvironment().volumetricFog.length == 89, "profile-free games retain direct native-fog control")
	validate_point_fog_energy(&ctx, &world, &manager, &registry, post, light, value)
	assert(len(manager.diagnostics.reported) == 0)
}

validate_point_fog_energy :: proc(ctx: ^bridge.Context, world: ^ecs.World, manager: ^assets.Asset_Manager,
	registry: ^ecs.Component_Registry, post, directional: ecs.Entity, value: ecs.PostProcessing) {
	ecs.destroy_entity(world, directional)
	point := ecs.create_entity(world)
	assert(ecs.add(world, registry, point, ecs.Transform{position={0,0,-8},scale={1,1,1}}))
	assert(ecs.add_component(world, registry, point, "PointLight",
		parse(`{"intensity":0.2,"fog_energy":1,"range":20,"specular":0,"shadows":true,"shadow_overrides":{"softness":0,"update_mode":"continuous"}}`)))
	profile := value
	profile.enabled = true
	assert(ecs.add(world, registry, post, profile))
	unboosted := sample_frame(ctx, world, manager)
	native, found := ctx.scene_lights[point]
	assert(found && r3d.GetLightEnergy(native) == 0.2 && r3d.GetLightFogEnergy(native) == 1)
	assert(ecs.set_runtime_field(world, registry, point, "PointLight", "fog_energy", json.Float(20)))
	ctx.frame_stats.light_properties_updated = 0
	bridge.create_scene_lights(ctx, world)
	assert(ctx.frame_stats.light_properties_updated == 1 && ctx.scene_lights[point] == native,
		"editing only fog energy updates one cached native property without replacing the light")
	assert(r3d.GetLightEnergy(native) == 0.2 && r3d.GetLightFogEnergy(native) == 20,
		"fog energy scales scattering independently of surface illumination")
	boosted := sample_frame(ctx, world, manager)
	fmt.println("point fog energy 1", unboosted, "point fog energy 20", boosted)
	assert(int(boosted.r) > int(unboosted.r)+30, "a dim point light can produce strong visible scattering through its fog multiplier")
	ctx.frame_stats.light_properties_updated = 0
	bridge.create_scene_lights(ctx, world)
	assert(ctx.frame_stats.light_properties_updated == 0, "unchanged fog energy must use the existing light-property cache")
	assert(ecs.set_runtime_field(world, registry, point, "PointLight", "fog_energy", json.Float(0)))
	zero := sample_frame(ctx, world, manager)
	fmt.println("point fog energy 0", zero)
	assert(zero.r < 5 && r3d.GetLightEnergy(native) == 0.2 && r3d.GetLightFogEnergy(native) == 0,
		"zero fog energy suppresses light scattering while retaining the light's surface energy")
	assert(ecs.set_runtime_field(world, registry, point, "PointLight", "fog_energy", nil))
	reset := sample_frame(ctx, world, manager)
	assert(r3d.GetLightFogEnergy(native) == 1 && reset.r == unboosted.r,
		"clearing fog energy restores the native multiplier without disabling scattering")
}

main :: proc() {
	assert(bridge.post_processing_environment(r3d.ENVIRONMENT_BASE, ecs.default_post_processing()).volumetricFog == r3d.ENVIRONMENT_BASE.volumetricFog)
	for arg in os.args[1:] {if arg == "--runtime" {validate_runtime()}}
	fmt.println("Volumetric fog validation passed")
}
