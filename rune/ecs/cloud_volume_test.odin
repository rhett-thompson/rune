package ecs

import "core:encoding/json"
import "core:math"
import "core:testing"

cloud_test_json :: proc(text:string) -> json.Value {
	value:json.Value
	assert(json.unmarshal(transmute([]u8)text,&value,allocator=context.temp_allocator)==nil)
	return value
}

@(test)
cloud_fine_noise_defaults_and_json_contract :: proc(t:^testing.T) {
	legacy,ok:=cloud_volume_from_json(cloud_test_json(`{"density":0.055,"noise_scale":85,"noise_offset":[7,13,19],"steps":24}`))
	testing.expect(t,ok && legacy.detail_offset==([3]f32{}) && legacy.detail_strength==0.28,
		"existing cloud data keeps the original fine octave and zero additional phase")
	current,valid:=cloud_volume_from_json(cloud_test_json(`{"detail_offset":[12,-8,0.25],"detail_strength":0.4}`))
	testing.expect(t,valid && current.detail_offset==([3]f32{12,-8,0.25}) && current.detail_strength==0.4)
	for endpoint in ([2]f32{0,1}) {
		current.detail_strength=endpoint
		testing.expect(t,cloud_volume_valid(current),"both fine-octave blend endpoints are supported")
	}
	for malformed in ([]string{
		`null`, `{"detail_offset":null}`, `{"detail_offset":0}`, `{"detail_offset":[1,2]}`,
		`{"detail_offset":[1,2,3,4]}`, `{"detail_offset":[1,true,3]}`, `{"detail_offset":[1,"2",3]}`,
		`{"detail_offset":[1,1e100,3]}`, `{"detail_strength":null}`, `{"detail_strength":true}`,
		`{"detail_strength":"0.3"}`, `{"detail_strength":-0.001}`, `{"detail_strength":1.001}`,
		`{"detail_strength":1e100}`, `{"detail_speed":1}`,
	}) {
		_,accepted:=cloud_volume_from_json(cloud_test_json(malformed))
		testing.expect(t,!accepted,malformed)
	}
}

@(test)
cloud_fine_noise_typed_writes_are_finite :: proc(t:^testing.T) {
	defaults:=default_cloud_volume()
	for bad in ([3]f32{math.nan_f32(),math.inf_f32(1),math.inf_f32(-1)}) {
		for axis in 0..<3 {
			candidate:=defaults; candidate.detail_offset[axis]=bad
			testing.expect(t,!cloud_volume_valid(candidate),"each fine phase axis rejects non-finite typed values")
		}
		candidate:=defaults; candidate.detail_strength=bad
		testing.expect(t,!cloud_volume_valid(candidate),"non-finite blend weights cannot reach the shader")
	}
}

@(test)
cloud_fine_noise_roundtrip_and_rejected_mutation :: proc(t:^testing.T) {
	lock_native_physics_test(); defer unlock_native_physics_test()
	w:=init(); defer destroy(&w)
	r:=init_registry(); defer destroy_registry(&r)
	assert(register_builtin_components(&r))
	e:=create_entity(&w)
	current:=default_cloud_volume(); current.detail_offset={17,-11,0.5}; current.detail_strength=0.4
	assert(add(&w,&r,e,current))
	data,serialized:=runtime_component_json(&w,e,"CloudVolume"); testing.expect(t,serialized)
	copy:=create_entity(&w); assert(add_component(&w,&r,copy,"CloudVolume",data))
	roundtrip,found:=get(&w,copy,CloudVolume)
	testing.expect(t,found && roundtrip==current,"reflection snapshots retain both independent detail controls")
	for bad in ([5]f32{-0.001,1.001,math.nan_f32(),math.inf_f32(1),math.inf_f32(-1)}) {
		candidate:=current; candidate.detail_strength=bad
		testing.expect(t,!set(&w,e,candidate) && !add(&w,&r,e,candidate))
		testing.expect(t,!set_runtime_field(&w,&r,e,"CloudVolume","detail_strength",json.Float(f64(bad))))
		unchanged,_:=get(&w,e,CloudVolume)
		testing.expect(t,unchanged==current,"rejected typed and inspector blend edits preserve the valid cloud")
	}
	for bad in ([]string{`{"detail_offset":[1,2]}`,`{"detail_offset":[1,1e100,3]}`,`{"detail_strength":1.01}`}) {
		testing.expect(t,!add_component(&w,&r,e,"CloudVolume",cloud_test_json(bad)))
		unchanged,_:=get(&w,e,CloudVolume)
		testing.expect(t,unchanged==current,"rejected JSON cannot replace a valid cloud")
	}
	assert(set_runtime_field(&w,&r,e,"CloudVolume","detail_strength",json.Float(0)))
	updated,_:=get(&w,e,CloudVolume)
	testing.expect(t,updated.detail_strength==0 && updated.detail_offset==current.detail_offset && updated.noise_offset==current.noise_offset,
		"an explicit zero fine contribution retains the authored phases and broad density")
}
