package r3d_bridge

import "rune:ecs"
import r3d "r3d:r3d"
import rl "vendor:raylib"

Light_Properties :: struct {
	frame: u64,
	position,direction: rl.Vector3,
	color: ecs.Color,
	energy,range,specular: f32,
}

sync_light_properties :: proc(ctx:^Context,e:ecs.Entity,id:r3d.Light,light:$T,position:rl.Vector3={}) {
	previous,found:=ctx.light_properties[e]
	force:=!found || ctx.render_optimizations_disabled
	current:=Light_Properties{frame=ctx.light_sync_frame,position=position,color=light.color,energy=light.intensity,range=light.range,specular=light.specular}
	when T==ecs.DirectionalLight || T==ecs.SpotLight {current.direction=light.direction}
	when T==ecs.SpotLight {
		if force || previous.position!=current.position || previous.direction!=current.direction {
			r3d.LightLookAt(id,position,position+light.direction); ctx.frame_stats.light_properties_updated+=1
		}
	} else when T==ecs.DirectionalLight {
		if force || previous.direction!=current.direction {r3d.SetLightDirection(id,light.direction); ctx.frame_stats.light_properties_updated+=1}
	} else {
		if force || previous.position!=current.position {r3d.SetLightPosition(id,position); ctx.frame_stats.light_properties_updated+=1}
	}
	if force || previous.color!=current.color {r3d.SetLightColor(id,to_raylib_color(light.color)); ctx.frame_stats.light_properties_updated+=1}
	if force || previous.energy!=current.energy {r3d.SetLightEnergy(id,light.intensity); ctx.frame_stats.light_properties_updated+=1}
	if force || previous.range!=current.range {r3d.SetLightRange(id,light.range); ctx.frame_stats.light_properties_updated+=1}
	if force || previous.specular!=current.specular {r3d.SetLightSpecular(id,light.specular); ctx.frame_stats.light_properties_updated+=1}
	if !r3d.IsLightActive(id) {r3d.SetLightActive(id,true)}
	ctx.light_properties[e]=current
}
