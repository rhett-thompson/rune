package main

import "core:math"
import "rune:ecs"

// Attach independently to the player and camera. Units are radians and seconds.
Orientation_Smoothing :: struct {
	max_turn_speed, angular_acceleration, easing_rate: f32,
	facing_turn_speed, facing_easing_rate: f32,
}
Default_Orientation_Smoothing :: Orientation_Smoothing {
	max_turn_speed=2.4, angular_acceleration=5, easing_rate=5,
	facing_turn_speed=8, facing_easing_rate=12,
}

register_planetary_components :: proc(registry:^ecs.Component_Registry)->bool {
	return ecs.register_component(registry,"OrientationSmoothing",Orientation_Smoothing,
		Default_Orientation_Smoothing,"Gravity alignment and movement-facing smoothing; radians and seconds")
}

orientation_positive :: proc(value,fallback:f32)->f32 {
	if value<=0 || math.is_nan(value) || math.is_inf(value) {return fallback}
	return value
}
orientation_settings :: proc(world:^ecs.World,entity:ecs.Entity)->Orientation_Smoothing {
	settings,found:=ecs.get(world,entity,Orientation_Smoothing)
	if !found {return Default_Orientation_Smoothing}
	// Custom components use Rune's reflected JSON loader. Guard live values at
	// consumption so accidental zero/negative edits cannot stall or invert a turn.
	d:=Default_Orientation_Smoothing
	settings.max_turn_speed=orientation_positive(settings.max_turn_speed,d.max_turn_speed)
	settings.angular_acceleration=orientation_positive(settings.angular_acceleration,d.angular_acceleration)
	settings.easing_rate=orientation_positive(settings.easing_rate,d.easing_rate)
	settings.facing_turn_speed=orientation_positive(settings.facing_turn_speed,d.facing_turn_speed)
	settings.facing_easing_rate=orientation_positive(settings.facing_easing_rate,d.facing_easing_rate)
	return settings
}
