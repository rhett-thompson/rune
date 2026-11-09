package audio

import "rune:ecs"

// Move an existing playback owner without reloading or restarting its sources.
// Use after scene replacement, before update removes the old World's players.
// Source handles may belong to a destroyed World; the destination must be live
// and have the same sound/ordered clips. Other destination settings apply on
// the next update. An occupied destination is never replaced implicitly.
// If moving within one World, remove the old AudioPlayer before update so its
// independent play_on_start configuration cannot start another instance.
rebind :: proc(
	system: ^Audio_System,
	world: ^ecs.World,
	source_entity: ecs.Entity,
	source_name: string,
	destination_entity: ecs.Entity,
	destination_name: string,
) -> bool {
	if system == nil || world == nil || !system.available || !ecs.is_alive(world,destination_entity) {return false}
	source := ecs.Component_Instance{entity=source_entity,name=source_name}
	destination := ecs.Component_Instance{entity=destination_entity,name=destination_name}
	instance, found := system.instances[source]
	if !found {return false}
	player, configured := ecs.get_audio_player(world,destination_entity,destination_name)
	if !configured || !same_clip_configuration(instance,player) {return false}
	if source == destination {return true}
	if _, occupied := system.instances[destination]; occupied {return false}
	destination.name = retain_string(system,destination_name)
	// Only the key changes: decoder cursor, native buffers, aliases, suspension,
	// pending stop fades and variation remain owned exactly once by this system.
	delete_key(&system.instances,source)
	system.instances[destination] = instance
	return true
}
