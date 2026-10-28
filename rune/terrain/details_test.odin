package terrain

import "core:encoding/json"
import "core:math"
import "core:testing"

detail_test_decode :: proc(text:string) -> ([]Detail,bool) {
	value:json.Value
	assert(json.unmarshal(transmute([]u8)text,&value,allocator=context.temp_allocator)==nil)
	object,ok:=value.(json.Object)
	assert(ok)
	return details_from_json(object)
}

@(test)
detail_density_defaults_preserve_existing_descriptors :: proc(t:^testing.T) {
	details,ok:=detail_test_decode(`{"details":[{}, {"kind":"model","model":"grass.obj"}]}`)
	if !testing.expect(t,ok && len(details)==2) {return}
	for d in details {
		testing.expect(t,d.density_distance==[2]f32{} && d.density_min==0.25,"density thinning is disabled when omitted")
	}
	testing.expect(t,details[0].draw_distance==60 && details[1].draw_distance==250,"existing per-kind distance defaults are unchanged")
}

@(test)
detail_density_decodes_builtin_and_custom_settings :: proc(t:^testing.T) {
	details,ok:=detail_test_decode(`{"details":[
		{"draw_distance":80,"density_distance":[10,60],"density_min":0.15},
		{"kind":"model","model":"grass.obj","draw_distance":140,"density_distance":[12,90],"density_min":0},
		{"density_distance":[0,60],"density_min":1},
		{"density_distance":[0,0],"density_min":0}
	]}`)
	if !testing.expect(t,ok && len(details)==4) {return}
	testing.expect(t,details[0].density_distance==[2]f32{10,60} && details[0].density_min==0.15)
	testing.expect(t,details[1].density_distance==[2]f32{12,90} && details[1].density_min==0,"custom models support fully thinning away")
	testing.expect(t,details[2].density_min==1 && details[3].density_distance==[2]f32{},"full density and explicit disable are valid")
}

@(test)
detail_density_rejects_invalid_ranges_and_types :: proc(t:^testing.T) {
	for document in ([]string{
		`{"details":[{"density_distance":[-1,40]}]}`,
		`{"details":[{"density_distance":[40,20]}]}`,
		`{"details":[{"density_distance":[20,20]}]}`,
		`{"details":[{"density_distance":[0,61]}]}`,
		`{"details":[{"density_distance":[0,10,20]}]}`,
		`{"details":[{"density_distance":["0",40]}]}`,
		`{"details":[{"density_distance":40}]}`,
		`{"details":[{"density_min":-0.01}]}`,
		`{"details":[{"density_min":1.01}]}`,
		`{"details":[{"density_min":"0.25"}]}`,
	}) {
		_,ok:=detail_test_decode(document)
		testing.expect(t,!ok,document)
	}
	d:=default_detail()
	d.density_min=math.nan_f32()
	testing.expect(t,!details_valid([]Detail{d}),"non-finite retention is rejected")
	d=default_detail();d.density_distance={0,math.inf_f32(1)}
	testing.expect(t,!details_valid([]Detail{d}),"non-finite distances are rejected")
}
