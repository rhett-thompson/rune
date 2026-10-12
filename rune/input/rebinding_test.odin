package input

import "core:os"
import "core:reflect"
import "core:strings"
import "core:testing"
import rl "vendor:raylib"

@(private="file")
rebinding_test_controls :: proc(t: ^testing.T) -> Input {
	file,err:=os.create_temp_file("","rune-rebinding-*.json")
	if !testing.expect(t,err==nil) {return {}}
	path,_:=strings.clone(os.name(file)); defer delete(path)
	testing.expect(t,os.close(file)==nil); defer os.remove(path)
	document := `{
	  "$schema":"schemas/custom-input.schema.json",
	  "actions":{
	    "move":[{"type":"keyboard","key":"w"},{"type":"keyboard","key":"UP"},{"type":"mouse_button","button":"left"},{"type":"gamepad_button","button":"DPAD_UP","gamepad":2}],
	    "left":[{"type":"keyboard","key":"a"}],
	    "right":[{"type":"keyboard","key":"D"}]
	  },
	  "axes":{
	    "horizontal":{"negative":"left","positive":"right","invert":true},
	    "mouse":{"type":"mouse_delta","axis":"y","scale":2,"invert":true},
	    "wheel":{"type":"mouse_wheel","scale":-2},
	    "stick":{"type":"gamepad_axis","axis":"RIGHT_X","gamepad":2,"deadzone":0.25,"scale":0.75,"invert":true}
	  }
	}`
	if !testing.expect(t,os.write_entire_file(path,transmute([]u8)document)==nil) {return {}}
	controls,valid:=load(path)
	testing.expect(t,valid)
	return controls
}

@(test)
rebinding_clone_owns_every_configuration_string_and_resets_samples :: proc(t: ^testing.T) {
	source:=rebinding_test_controls(t); defer destroy(&source)
	source.actions["move"]={is_down=true,pressed=true,strength=1}
	source.axes["mouse"]=7; inject_action(&source,"move",true); source.captured=true
	draft,valid:=clone(&source); if !testing.expect(t,valid) {return}; defer destroy(&draft)
	testing.expect(t,draft.arena!=source.arena && draft.path==source.path && draft.schema==source.schema && draft.has_schema,
		"clone has independent ownership and preserves document metadata")
	testing.expect(t,len(draft.actions)==0 && len(draft.injected)==0 && len(draft.axes)==0 && !draft.captured,
		"draft configuration has no held actions, injected edges or stale analog samples")
	for name,bindings in source.mappings.actions {
		copied:=draft.mappings.actions[name]
		testing.expect(t,len(copied)==len(bindings) && raw_data(copied)!=raw_data(bindings))
		for binding,index in bindings {testing.expect(t,copied[index]==binding,"all action slots are copied exactly")}
	}
	for name,axis in source.mappings.axes {testing.expect(t,draft.mappings.axes[name]==axis,"axis variants and every parameter are preserved")}
	path,schema:=strings.clone(draft.path) or_else "",strings.clone(draft.schema) or_else ""
	defer delete(path); defer delete(schema)
	destroy(&source)
	testing.expect(t,draft.path==path && draft.schema==schema && validate_mappings(draft.mappings),
		"destroying the original cannot invalidate draft strings or maps")
	testing.expect(t,rebind(&draft,"move",1,{type="keyboard",key="LEFT_CTRL"}))
	testing.expect(t,draft.mappings.actions["move"][1].key=="LEFT_CONTROL")
	_,valid=clone(nil); testing.expect(t,!valid)
}

@(test)
rebinding_replaces_any_slot_across_devices_without_touching_axes :: proc(t: ^testing.T) {
	controls:=rebinding_test_controls(t); defer destroy(&controls)
	snapshot,valid:=clone(&controls); if !testing.expect(t,valid) {return}; defer destroy(&snapshot)
	bindings:=[]Binding{{type="keyboard",key="right_ctrl",button="ignored",gamepad=9},
		{type="mouse_button",button="extra",key="ignored",gamepad=9},
		{type="gamepad_button",button="right_trigger",gamepad=3,key="ignored"}}
	for binding in bindings {
		testing.expect(t,rebind(&controls,"move",1,binding))
		canonical,ok:=canonical_binding(binding)
		testing.expect(t,ok && controls.mappings.actions["move"][1]==canonical)
		for original,index in snapshot.mappings.actions["move"] {
			if index!=1 {testing.expect(t,controls.mappings.actions["move"][index]==original,
				"editing a second slot preserves the first keyboard and other device slots")}
		}
		for name,axis in snapshot.mappings.axes {testing.expect(t,controls.mappings.axes[name]==axis)}
		testing.expect(t,controls.path==snapshot.path && controls.schema==snapshot.schema && controls.has_schema)
	}
	before:=controls.mappings.actions["move"][1]
	for invalid in ([]Binding{{type="keyboard",key="UNKNOWN"},{type="mouse_button",button="UNKNOWN"},
		{type="gamepad_button",button="A",gamepad=-1},{type="gamepad_axis",button="A"}}) {
		testing.expect(t,!rebind(&controls,"move",1,invalid) && controls.mappings.actions["move"][1]==before,
			"invalid proposals do not partly change the selected slot")
	}
	testing.expect(t,!rebind(&controls,"missing",0,{type="keyboard",key="X"}))
	testing.expect(t,!rebind(&controls,"move",-1,{type="keyboard",key="X"}))
	testing.expect(t,!rebind(&controls,"move",4,{type="keyboard",key="X"}))
	testing.expect(t,!rebind(nil,"move",0,{type="keyboard",key="X"}))
}

@(test)
rebinding_configuration_replacement_is_atomic_with_stable_target_address :: proc(t: ^testing.T) {
	target:=rebinding_test_controls(t); defer destroy(&target)
	source,valid:=clone(&target); if !testing.expect(t,valid) {return}; defer destroy(&source)
	target_address:=&target
	target.actions["move"]={is_down=true,pressed=true,strength=1}; inject_action(&target,"move",true); target.axes["mouse"]=5
	rebind(&source,"move",0,{type="keyboard",key="INSERT"})
	old_arena:=target.arena
	invalid,ok:=clone(&source); if !testing.expect(t,ok) {return}; defer destroy(&invalid)
	invalid.mappings.actions["move"][0]={type="keyboard",key="UNKNOWN"}
	testing.expect(t,!replace_configuration(&target,&invalid) && target.arena==old_arena && target.actions["move"].is_down && len(target.injected)==1,
		"invalid replacements retain target configuration, ownership and live state")
	testing.expect(t,replace_configuration(&target,&source) && &target==target_address && target.arena!=old_arena && target.arena!=source.arena)
	testing.expect(t,target.mappings.actions["move"][0].key=="INSERT" && source.mappings.actions["move"][0].key=="INSERT")
	testing.expect(t,target.captured && len(target.actions)==0 && len(target.injected)==0 && len(target.axes)==0)
	testing.expect(t,!pressed(&target,"move") && axis(&target,"mouse")==0,"installation suppresses all pending gameplay edges and analog samples")
	testing.expect(t,replace_configuration(&target,&target),"self replacement clones before destruction")
	testing.expect(t,target.mappings.actions["move"][0].key=="INSERT" && target.captured)
	testing.expect(t,!replace_configuration(nil,&source))
}

@(test)
rebinding_owned_configuration_move_consumes_source_without_allocation :: proc(t: ^testing.T) {
	target:=rebinding_test_controls(t); defer destroy(&target)
	prepared,valid:=clone(&target); if !testing.expect(t,valid) {return}; defer destroy(&prepared)
	prepared.actions["move"]={pressed=true,is_down=true,strength=1}; inject_action(&prepared,"move",true); prepared.axes["stick"]=0.5
	rebind(&prepared,"move",2,{type="gamepad_button",button="X",gamepad=1})
	prepared_arena:=prepared.arena
	testing.expect(t,move_configuration(&target,&prepared) && target.arena==prepared_arena && prepared.arena==nil && prepared.path=="",
		"prepared arena transfers directly and only the target owns it afterward")
	testing.expect(t,target.captured && len(target.actions)==0 && len(target.injected)==0 && len(target.axes)==0)
	testing.expect(t,target.mappings.actions["move"][2]==Binding{type="gamepad_button",button="X",gamepad=1})
	testing.expect(t,!move_configuration(&target,&target) && target.arena==prepared_arena)
	alias:=target
	testing.expect(t,!move_configuration(&target,&alias) && !replace_configuration(&target,&alias),
		"accidental shallow aliases must not double-free their shared arena")
	alias={}
	borrowed:=Input{mappings=target.mappings}
	testing.expect(t,!move_configuration(&target,&borrowed),"a borrowed configuration cannot transfer ownership")
	owned,owned_valid:=clone(&borrowed); defer destroy(&owned)
	testing.expect(t,owned_valid,"borrowed mappings can still be copied into an owned draft")
}

@(test)
rebinding_canonical_names_compare_aliases_and_round_trip_native_codes :: proc(t: ^testing.T) {
	testing.expect(t,binding_equal({type="keyboard",key="esc",button="ignored",gamepad=3},{type="keyboard",key="ESCAPE"}))
	testing.expect(t,binding_equal({type="keyboard",key="left_ctrl"},{type="keyboard",key="LEFT_CONTROL"}))
	testing.expect(t,binding_equal({type="gamepad_button",button="a",gamepad=2},{type="gamepad_button",button="A",gamepad=2}))
	testing.expect(t,!binding_equal({type="gamepad_button",button="A",gamepad=1},{type="gamepad_button",button="A",gamepad=2}))
	testing.expect(t,!binding_equal({type="keyboard",key="A"},{type="gamepad_button",button="A"}))
	testing.expect(t,!binding_equal({type="keyboard",key="UNKNOWN"},{type="keyboard",key="UNKNOWN"}))
	for field in reflect.enum_fields_zipped(rl.KeyboardKey) {
		key:=rl.KeyboardKey(field.value)
		if key==.KEY_NULL {continue}
		name:=keyboard_key_name(key)
		result:=key_from_name(name)
		testing.expect(t,name!="" && result.valid && result.key==key,"every native keyboard capture name round-trips through declarative mappings")
	}
	for field in reflect.enum_fields_zipped(rl.MouseButton) {
		button:=rl.MouseButton(field.value)
		name:=mouse_button_name(button)
		result:=mouse_button_from_name(name)
		testing.expect(t,name!="" && result.valid && result.button==button)
	}
	for field in reflect.enum_fields_zipped(rl.GamepadButton) {
		button:=rl.GamepadButton(field.value)
		if button==.UNKNOWN {continue}
		name:=gamepad_button_name(button)
		result:=button_from_name(name)
		testing.expect(t,name!="" && result.valid && result.button==button)
	}
	testing.expect(t,keyboard_key_name(.KEY_NULL)=="" && keyboard_key_name(rl.KeyboardKey(1000))=="")
	testing.expect(t,mouse_button_name(rl.MouseButton(1000))=="" && gamepad_button_name(.UNKNOWN)=="" && gamepad_button_name(rl.GamepadButton(1000))=="")
}
