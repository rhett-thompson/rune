package ecs

import "core:encoding/json"

// Ellipsoidal participating medium within the entity's transformed unit cube.
// Transform.scale gives full XYZ dimensions; it creates no collision or mesh.
CloudVolume :: struct {
	color, shadow_color: [4]u8,
	density, noise_scale, coverage: f32,
	noise_offset: [3]f32,
	steps: i32,
}

default_cloud_volume :: proc() -> CloudVolume {
	return {color={218,230,242,255},shadow_color={90,112,140,255},density=0.035,noise_scale=90,coverage=0.55,steps=32}
}

cloud_volume_valid :: proc(v: CloudVolume) -> bool {
	return finite_nonnegative(v.density) && v.density<=10 && finite_nonnegative(v.noise_scale) && v.noise_scale>=0.01 &&
		finite_nonnegative(v.coverage) && v.coverage<=1 && physics_query_vector_valid(v.noise_offset) && v.steps>=8 && v.steps<=96
}

cloud_volume_from_json :: proc(data: json.Value) -> (CloudVolume,bool) {
	if !post_processing_json_shape_valid(data,CloudVolume) {return {},false}
	v:=default_cloud_volume()
	bytes,err:=json.marshal(data,allocator=context.temp_allocator)
	if err!=nil || json.unmarshal(bytes,&v,allocator=context.temp_allocator)!=nil {return {},false}
	return v,cloud_volume_valid(v)
}
