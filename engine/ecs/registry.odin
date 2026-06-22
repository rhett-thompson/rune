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
	orbit_registered := register_component(registry, Component_Descriptor{name = "Orbit", description = "Moves an entity around its parent on the XZ plane"})
	rotator_registered := register_component(registry, Component_Descriptor{name = "Rotator", description = "Spins an entity around its local Y axis"})
	return transform_registered && sprite_registered && mesh_registered && sphere_registered && orbit_registered && rotator_registered
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
