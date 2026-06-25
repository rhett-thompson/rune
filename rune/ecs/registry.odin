package ecs

Component_Descriptor :: struct {
	name:        string,
	description: string,
}

Component_Registry :: struct {
	components: map[string]Component_Descriptor,
}

init_registry :: proc() -> Component_Registry {
	return Component_Registry{components = make(map[string]Component_Descriptor)}
}

register_builtin_components :: proc(registry: ^Component_Registry) -> bool {
	transform_registered := register_component(registry, Component_Descriptor{
		name = "Transform",
		description = "Position, rotation, and scale for an entity",
	})
	sprite_registered := register_component(registry, Component_Descriptor{name = "SpriteRenderer", description = "2D texture renderer"})
	mesh_registered := register_component(registry, Component_Descriptor{name = "MeshRenderer", description = "Primitive 3D mesh renderer"})
	sphere_registered := register_component(registry, Component_Descriptor{name = "SphereRenderer", description = "Sphere 3D renderer"})
	model_registered := register_component(registry, Component_Descriptor{name = "ModelRenderer", description = "Asset-backed 3D model renderer"})
	tilemap_registered := register_component(registry, Component_Descriptor{name = "TilemapRenderer", description = "Texture-atlas 2D tile grid"})
	text_registered := register_component(registry, Component_Descriptor{name = "TextRenderer", description = "Scene-authored 2D text"})
	tilemap_collider_registered := register_component(registry, Component_Descriptor{name = "TilemapCollider", description = "Solid-tile collision for a TilemapRenderer"})
	top_down_controller_registered := register_component(registry, Component_Descriptor{name = "TopDownController", description = "2D tilemap collision controller"})
	rigid_body_2d_registered := register_component(registry, Component_Descriptor{name = "RigidBody2D", description = "Fixed-step 2D physics body"})
	box_collider_2d_registered := register_component(registry, Component_Descriptor{name = "BoxCollider2D", description = "2D axis-aligned box collider"})
	circle_collider_2d_registered := register_component(registry, Component_Descriptor{name = "CircleCollider2D", description = "2D circle collider"})
	box_collider_registered := register_component(registry, Component_Descriptor{name = "BoxCollider", description = "Axis-aligned static collision volume"})
	sphere_collider_registered := register_component(registry, Component_Descriptor{name = "SphereCollider", description = "Sphere-shaped static collision volume"})
	character_controller_registered := register_component(registry, Component_Descriptor{name = "CharacterController", description = "Gravity and collision player controller"})
	orbit_registered := register_component(registry, Component_Descriptor{name = "Orbit", description = "Moves an entity around its parent on the XZ plane"})
	rotator_registered := register_component(registry, Component_Descriptor{name = "Rotator", description = "Spins an entity around its local Y axis"})
	camera_2d_registered := register_component(registry, Component_Descriptor{name = "Camera2D", description = "2D view controlled by an entity Transform"})
	camera_3d_registered := register_component(registry, Component_Descriptor{name = "Camera3D", description = "3D view controlled by an entity Transform"})
	audio_listener_registered := register_component(registry, Component_Descriptor{name = "AudioListener", description = "Scene audio reference point, normally attached to the active camera"})
	audio_player_registered := register_component(registry, Component_Descriptor{name = "AudioPlayer", description = "Entity sound playback settings"})
	return transform_registered && sprite_registered && mesh_registered && sphere_registered && model_registered && tilemap_registered && text_registered && tilemap_collider_registered && top_down_controller_registered && rigid_body_2d_registered && box_collider_2d_registered && circle_collider_2d_registered && box_collider_registered && sphere_collider_registered && character_controller_registered && orbit_registered && rotator_registered && camera_2d_registered && camera_3d_registered && audio_listener_registered && audio_player_registered
}

// register_component makes a component name available to a World. The component's
// data is deliberately JSON for now: game code owns its behaviour while scenes and
// prefabs remain readable and editable without a reflection system.
register_component :: proc(registry: ^Component_Registry, descriptor: Component_Descriptor) -> bool {
	if len(descriptor.name) == 0 || has_component(registry, descriptor.name) {
		return false
	}

	registry.components[descriptor.name] = descriptor
	return true
}

has_component :: proc(registry: ^Component_Registry, name: string) -> bool {
	_, found := registry.components[name]
	return found
}
