package terrain

import "core:math"
import "core:math/linalg"

// Packed linear RGBA8 control data. Width and height describe one group;
// the two groups are stacked vertically, with X varying fastest.
Control_Map :: struct {
	width, height: int,
	pixels: []u8,
}

// This matches the bridge's material parameter encoding.
layer_weight_source :: proc(layer: Layer) -> int {
	switch layer.weight_source {
	case "bands": return 1
	case "paint_and_bands": return 2
	case: return 0
	}
}

// Effective material weights at local X/Z. Pass the same packed control
// pixels used for rendering when a nonzero layer uses paint.
layer_weights :: proc(data: Data, x,z: f32, controls: ^Control_Map = nil) -> ([MAX_LAYERS]f32,bool) {
	weights,total,ready := evaluate_layer_weights(data,x,z,controls)
	if !ready {return {},false}
	for &weight in weights {weight /= total}
	return weights,true
}

@(private)
evaluate_layer_weights :: proc(data: Data, x,z: f32, controls: ^Control_Map) -> ([MAX_LAYERS]f32,f32,bool) {
	d := data.description
	if len(d.layers) == 0 || len(d.layers) > MAX_LAYERS ||
	   !(d.size[0] > 0 && d.size[1] > 0 && x >= 0 && z >= 0 && x <= d.size[0] && z <= d.size[1]) {return {},0,false}
	use_controls := len(d.control_maps) != 0
	needs_bands := false
	needs_controls := false
	for layer in d.layers {
		if layer.weight == 0 {continue}
		source := layer_weight_source(layer)
		needs_bands = needs_bands || !use_controls || source != 0
		needs_controls = needs_controls || (use_controls && source != 1)
	}
	if needs_controls && (controls == nil || controls.width < 1 || controls.width > 2048 ||
	   controls.height < 1 || controls.height > 2048 || len(controls.pixels) != 8*controls.width*controls.height) {return {},0,false}

	height,slope: f32
	if needs_bands {
		w,h := d.resolution[0],d.resolution[1]
		if w < 2 || h < 2 || w > 513 || h > 513 || len(data.heights) != w*h {return {},0,false}
		height,_ = sample_height(data,x,z)
		slope = layer_slope(data,x,z)
	}
	uv := [2]f32{x/d.size[0], z/d.size[1]}
	weights: [MAX_LAYERS]f32
	total: f32
	for layer,i in d.layers {
		if layer.weight == 0 {continue}
		weight := layer.weight
		source := layer_weight_source(layer)
		if use_controls && source != 1 {weight *= control_channel(controls,uv,i)}
		if !use_controls || source != 0 {weight *= layer_band(layer.height,height)*layer_band(layer.slope,slope)}
		weights[i] = weight
		total += weight
	}
	// Preserve the renderer's small-total fallback, including its threshold.
	if total < 0.00001 {weights[0] = 1; total = 1}
	return weights,total,true
}

// Sum the effective weights of all layers with this exact gameplay tag.
surface_weight :: proc(data: Data, x,z: f32, surface: string, controls: ^Control_Map = nil) -> (f32,bool) {
	if surface == "" {return 0,false}
	weights,total,ready := evaluate_layer_weights(data,x,z,controls)
	if !ready {return 0,false}
	weight: f32
	found := false
	for layer,i in data.description.layers {
		if layer.surface == surface {weight += weights[i]; found = true}
	}
	return min(weight/total,1),found
}

@(private)
layer_ramp :: proc(start,end,value: f32) -> f32 {
	if start == end {return 1 if value >= start else 0}
	t := clamp((value-start)/(end-start),0,1)
	return t*t*(3-2*t)
}

@(private)
layer_band :: proc(range: [4]f32, value: f32) -> f32 {
	return layer_ramp(range[0],range[1],value)*(1-layer_ramp(range[2],range[3],value))
}

@(private)
layer_slope :: proc(data: Data, x,z: f32) -> f32 {
	d := data.description
	gx,gz := x/d.size[0]*f32(d.resolution[0]-1),z/d.size[1]*f32(d.resolution[1]-1)
	ix,iz := min(int(math.floor(gx)),d.resolution[0]-2),min(int(math.floor(gz)),d.resolution[1]-2)
	u,v := gx-f32(ix),gz-f32(iz)
	b,c := layer_vertex_normal(data,ix+1,iz),layer_vertex_normal(data,ix,iz+1)
	// The material shader interpolates the mesh's vertex normals before
	// normalization. The separate detail slope constraint uses a face normal.
	n: [3]f32
	if u+v <= 1 {
		a := layer_vertex_normal(data,ix,iz)
		n = a+(b-a)*u+(c-a)*v
	} else {
		e := layer_vertex_normal(data,ix+1,iz+1)
		n = e+(c-e)*(1-u)+(b-e)*(1-v)
	}
	return math.acos(clamp(linalg.normalize(n)[1],0,1))*180/f32(math.PI)
}

@(private)
layer_vertex_normal :: proc(data: Data, x,z: int) -> [3]f32 {
	n := normal(data,x,z)
	// R3D uploads normals as signed normalized bytes. Match the decoded
	// attributes before interpolation, especially at hard slope cutoffs.
	for &component in n {component = math.round(clamp(component,-1,1)*127)/127}
	return n
}

@(private)
control_channel :: proc(controls: ^Control_Map, uv: [2]f32, layer: int) -> f32 {
	// Clamp to the centers of the first and last texels in this group.
	x := clamp(uv.x*f32(controls.width)-0.5,0,f32(controls.width-1))
	z := clamp(uv.y*f32(controls.height)-0.5,0,f32(controls.height-1))
	x0,z0 := int(x),int(z)
	x1,z1 := min(x0+1,controls.width-1),min(z0+1,controls.height-1)
	u,v := x-f32(x0),z-f32(z0)
	group := layer/4*controls.height
	channel := layer%4
	a := f32(controls.pixels[4*((group+z0)*controls.width+x0)+channel])/255
	b := f32(controls.pixels[4*((group+z0)*controls.width+x1)+channel])/255
	c := f32(controls.pixels[4*((group+z1)*controls.width+x0)+channel])/255
	d := f32(controls.pixels[4*((group+z1)*controls.width+x1)+channel])/255
	top,bottom := a+(b-a)*u,c+(d-c)*u
	return top+(bottom-top)*v
}
