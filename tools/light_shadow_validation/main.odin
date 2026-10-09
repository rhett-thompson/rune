package main

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import "rune:assets"
import "rune:ecs"
import "rune:shadows"
import bridge "rune:r3d_bridge"
import r3d "r3d:r3d"
import rl "vendor:raylib"

parse :: proc(text: string) -> json.Value {
	value:json.Value
	assert(json.unmarshal(transmute([]u8)text,&value,allocator=context.temp_allocator)==nil)
	return value
}

Profile_Path :: "build/shadow-profiles-validation.shadow.json"
Profile_Text :: `{"enabled":true,"softness":1.5,"opacity":0.75,"depth_bias":0.006,"slope_bias":0.01,"update_mode":"interval","interval_ms":350}`

write_profile :: proc(text: string) -> os.Error {
	// Separate writes on filesystems whose modification stamps are coarse.
	time.sleep(20*time.Millisecond)
	return os.write_entire_file(Profile_Path,text)
}

validate_data :: proc() {
	assert(ecs.json_values_equal(parse("null"),nil) && ecs.json_values_equal(parse("null"),parse("null")))
	assert(!ecs.json_values_equal(parse("null"),json.Boolean(false)))
	s,ok:=shadows.from_json(parse(`{}`))
	assert(ok && s==shadows.Defaults)
	o:shadows.Overrides
	o,ok=shadows.overrides_from_json(parse(`{"enabled":false,"softness":0,"depth_bias":0,"opacity":0,"update_mode":"manual"}`))
	assert(ok)
	s=shadows.resolve(shadows.Defaults,o)
	assert(!s.enabled && s.softness==0 && s.depth_bias==0 && s.opacity==0 && s.update_mode=="manual")
	for text in ([]string{`{"opacity":1.1}`,`{"softness":-1}`,`{"enabled":null}`,`{"enabled":1}`,`{"interval_ms":0}`,`{"interval_ms":1.5}`,`{"update_mode":"sometimes"}`,`{"resoluton":512}`,`{"depth_bias":1e40}`,`{"$schema":1}`}) {
		_,valid:=shadows.from_json(parse(text)); assert(!valid,"invalid profiles must be rejected")
	}
	r:=ecs.init_registry(); defer ecs.destroy_registry(&r); assert(ecs.register_builtin_components(&r))
	w:=ecs.init(); defer ecs.destroy(&w)
	for component in ([]string{"DirectionalLight","PointLight","SpotLight"}) {
		e:=ecs.create_entity(&w)
		assert(ecs.add_component(&w,&r,e,component,parse(`{"shadow_profile":"assets/shared.shadow.json","shadow_overrides":{"enabled":false,"softness":0}}`)))
		value,ok:=ecs.runtime_component_json(&w,e,component); assert(ok)
		copy:=ecs.create_entity(&w)
		assert(ecs.add_component(&w,&r,copy,component,value),"snapshots must preserve profiles and explicit false/zero overrides")
		assert(ecs.set_runtime_field(&w,&r,e,component,"shadow_overrides.enabled",json.Boolean(true)))
		assert(ecs.set_runtime_field(&w,&r,e,component,"shadow_overrides.enabled",nil),"null restores inheritance")
		assert(!ecs.set_runtime_field(&w,&r,e,component,"shadow_overrides.opacity",json.Float(2)))
		assert(!ecs.add_component(&w,&r,e,component,parse(`{"shadow_overrides":{"unknown":0}}`)))
	}
	e:=ecs.create_entity(&w)
	assert(ecs.add(&w,&r,e,ecs.PointLight{range=5,shadow_opacity=1}))
	owned:=strings.clone("assets/owned.shadow.json")
	light,_:=ecs.get_point_light(&w,e)
	light.shadow_profile=owned
	assert(ecs.set_point_light(&w,e,light)); delete(owned)
	light,_=ecs.get_point_light(&w,e)
	assert(light.shadow_profile=="assets/owned.shadow.json","typed setters must retain profile paths")
	light.shadow_overrides.interval_ms=0
	assert(!ecs.set_point_light(&w,e,light),"typed setters must reject invalid overrides")
	fmt.println("Shadow profile data validation passed")
}

validate_assets :: proc() {
	m:=assets.Asset_Manager{root=".",retained_paths=make(map[string]string),diagnostics=assets.init_diagnostic_log()}
	defer {delete(m.shadow_profiles); assets.destroy_diagnostic_log(&m.diagnostics); assets.destroy_retained_paths(&m)}
	defer os.remove(Profile_Path)
	assert(write_profile(Profile_Text)==nil)
	s,revision,ok:=assets.shadow_profile(&m,Profile_Path)
	assert(ok && revision==1 && s.enabled && s.update_mode=="interval" && s.interval_ms==350)
	assert(write_profile(`{"enabled":false,"softness":0}`)==nil)
	assets.refresh_shadow_profiles(&m)
	s,revision,ok=assets.shadow_profile(&m,Profile_Path)
	assert(ok && revision==2 && !s.enabled && s.softness==0,"changed profiles must reload")
	assert(write_profile(`{"softness":-1}`)==nil)
	assets.refresh_shadow_profiles(&m)
	last:shadows.Settings
	last,revision,ok=assets.shadow_profile(&m,Profile_Path)
	assert(ok && revision==2 && last==s,"invalid edits must preserve the last valid profile")
	assert(os.remove(Profile_Path)==nil)
	assets.refresh_shadow_profiles(&m)
	last,revision,ok=assets.shadow_profile(&m,Profile_Path)
	assert(ok && revision==2 && last==s,"deleted profiles must preserve the last valid data")
	assert(write_profile(Profile_Text)==nil)
	assets.refresh_shadow_profiles(&m)
	_,revision,ok=assets.shadow_profile(&m,Profile_Path)
	assert(ok && revision==3 && len(m.diagnostics.reported)==0,"valid recovery must clear diagnostics")
	_,_,ok=assets.shadow_profile(&m,"build/missing-shadow-profile.shadow.json")
	assert(!ok,"a missing first load must not silently enable shadows")
	fmt.println("Shadow profile asset reload validation passed")
}

validate_runtime :: proc() {
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(320,240,"Light shadow validation")
	defer rl.CloseWindow()
	ctx,ok := bridge.init(".",320,240)
	assert(ok)
	defer bridge.shutdown(&ctx)
	validate_directional_stability()
	validate_light_hierarchy(&ctx)
	m:=assets.init("."); defer assets.shutdown(&m)
	defer os.remove(Profile_Path)
	registry := ecs.init_registry()
	defer ecs.destroy_registry(&registry)
	assert(ecs.register_builtin_components(&registry))
	w := ecs.init()
	defer ecs.destroy(&w)
	for component in ([]string{"DirectionalLight","PointLight","SpotLight"}) {
		entity := ecs.create_entity(&w)
		assert(ecs.add(&w,&registry,entity,ecs.Transform{scale={1,1,1}}))
		data: json.Value
		text := `{"intensity":1,"shadows":false}`
		assert(json.unmarshal(transmute([]u8)text, &data, allocator=context.temp_allocator)==nil)
		assert(ecs.add_component(&w,&registry,entity,component,data))
		bridge.create_scene_lights(&ctx,&w)
		light,found := ctx.scene_lights[entity]
		assert(found && light!=0 && r3d.IsLightValid(light) && r3d.IsLightEnabled(light))
		assert(!r3d.IsShadowEnabled(light),"new unshadowed lights must remain unshadowed")
		assert(ctx.scene_shadow_defaults[entity].interval_ms==16,"native seconds must preserve the default millisecond interval")
		for enabled in ([4]bool{true,false,true,false}) {
			// Use the console's mutation path, then the renderer's per-frame sync.
			assert(ecs.set_runtime_field(&w,&registry,entity,component,"shadows",json.Boolean(enabled)))
			bridge.create_scene_lights(&ctx,&w)
			assert(ctx.scene_lights[entity]==light,"toggling shadows must retain the native light")
			assert(r3d.IsShadowEnabled(light)==enabled,"runtime shadow toggles must update the native renderer both ways")
		}
		assert(write_profile(Profile_Text)==nil)
		// Force this fixture's next load even when reused between light types.
		assets.load_shadow_profile(&m,Profile_Path,.Reload)
		assert(ecs.set_runtime_field(&w,&registry,entity,component,"shadow_profile",json.String(Profile_Path)))
		bridge.create_scene_lights(&ctx,&w,&m)
		assert(r3d.IsShadowEnabled(light),"profile must replace legacy flat shadow settings")
		assert(r3d.GetShadowUpdateMode(light)==.INTERVAL && math.abs(r3d.GetShadowUpdateInterval(light)-0.35)<0.000001,"profile milliseconds must reach the native renderer as seconds")
		assert(r3d.GetShadowSoftness(light)==1.5 && r3d.GetShadowOpacity(light)==0.75)
		assert(ecs.set_runtime_field(&w,&registry,entity,component,"shadow_overrides.interval_ms",json.Integer(1)))
		bridge.create_scene_lights(&ctx,&w,&m)
		assert(math.abs(r3d.GetShadowUpdateInterval(light)-0.001)<0.000001,"one-millisecond overrides must retain their duration")
		assert(ecs.set_runtime_field(&w,&registry,entity,component,"shadow_overrides.interval_ms",nil))
		bridge.create_scene_lights(&ctx,&w,&m)
		assert(math.abs(r3d.GetShadowUpdateInterval(light)-0.35)<0.000001,"removing an interval override must restore the profile duration")
		ctx.shadows_disabled=true
		bridge.create_scene_lights(&ctx,&w,&m); assert(!r3d.IsShadowEnabled(light))
		ctx.shadows_disabled=false
		bridge.create_scene_lights(&ctx,&w,&m); assert(r3d.IsShadowEnabled(light))
		assert(ecs.set_runtime_field(&w,&registry,entity,component,"shadows_disabled",json.Boolean(true)))
		bridge.create_scene_lights(&ctx,&w,&m); assert(!r3d.IsShadowEnabled(light))
		assert(ecs.set_runtime_field(&w,&registry,entity,component,"shadows_disabled",json.Boolean(false)))
		assert(ecs.set_runtime_field(&w,&registry,entity,component,"shadow_overrides.enabled",json.Boolean(false)))
		bridge.create_scene_lights(&ctx,&w,&m); assert(!r3d.IsShadowEnabled(light))
		assert(ecs.set_runtime_field(&w,&registry,entity,component,"shadow_overrides.enabled",nil))
		assert(write_profile(`{"enabled":true,"softness":0,"depth_bias":0,"slope_bias":0,"update_mode":"manual"}`)==nil)
		assets.refresh_shadow_profiles(&m)
		bridge.create_scene_lights(&ctx,&w,&m)
		assert(r3d.IsShadowEnabled(light) && r3d.GetShadowUpdateMode(light)==.MANUAL)
		assert(r3d.GetShadowSoftness(light)==0 && r3d.GetShadowDepthBias(light)==0 && r3d.GetShadowSlopeBias(light)==0,"profile edits must reset zero values")
		assert(bridge.request_shadow_update(&ctx,entity))
		assert(write_profile(`{"enabled":false}`)==nil)
		assets.refresh_shadow_profiles(&m)
		bridge.create_scene_lights(&ctx,&w,&m); assert(!r3d.IsShadowEnabled(light))
		assert(ecs.set_runtime_field(&w,&registry,entity,component,"shadow_profile",json.String("")))
		assert(ecs.set_runtime_field(&w,&registry,entity,component,"shadows",json.Boolean(true)))
		bridge.create_scene_lights(&ctx,&w,&m)
		assert(r3d.GetShadowUpdateMode(light)==.INTERVAL && math.abs(r3d.GetShadowUpdateInterval(light)-0.016)<0.000001 && r3d.IsShadowEnabled(light),"removing a profile must restore native legacy behavior")
		assert(ecs.set_runtime_field(&w,&registry,entity,component,"shadow_profile",json.String("build/missing-shadow-profile.shadow.json")))
		assert(ecs.set_runtime_field(&w,&registry,entity,component,"shadow_overrides.enabled",json.Boolean(true)))
		bridge.create_scene_lights(&ctx,&w,&m)
		assert(!r3d.IsShadowEnabled(light),"missing first loads must disable shadows even with an enabled override")
		assert(ctx.scene_lights[entity]==light)
		ecs.destroy_entity(&w,entity)
		bridge.create_scene_lights(&ctx,&w)
		assert(!r3d.IsLightValid(light),"removed lights must release native state")
	}
	fmt.println("Light shadow runtime validation passed")
}

main :: proc() {
	validate_data()
	validate_assets()
	for argument in os.args[1:] {if argument=="--runtime" {validate_runtime(); return}}
}



