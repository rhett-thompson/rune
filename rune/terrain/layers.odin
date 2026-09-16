package terrain

import "core:encoding/json"
import "core:strings"
import "rune:jsonutil"

MAX_LAYERS :: 8

// Each four-value range is fade-in start/end, then fade-out start/end.
Layer :: struct {
	name, material: string,
	tile_size: [2]f32,
	height, slope: [4]f32,
	weight: f32,
}

default_layer :: proc() -> Layer {
	return {tile_size={4,4},height={-100001,-100000,100000,100001},slope={-1,0,90,91},weight=1}
}

layers_valid :: proc(d: Description) -> bool {
	if len(d.layers)>MAX_LAYERS || len(d.control_maps)>2 {return false}
	if len(d.layers)==0 {return len(d.control_maps)==0}
	if blend_enabled(d.blend) {return false}
	if len(d.control_maps)>0 && len(d.control_maps)!=(len(d.layers)+3)/4 {return false}
	for path in d.control_maps {if path=="" {return false}}
	for layer in d.layers {
		if layer.material=="" || !(layer.weight>=0 && layer.weight<=1000) {return false}
		for size in layer.tile_size {if !(size>=0.001 && size<=100000) {return false}}
		for range,i in ([2][4]f32{layer.height,layer.slope}) {
			limit:f32=100001 if i==0 else 91
			for value in range {if !(value>=-limit && value<=limit) {return false}}
			if range[0]>range[1] || range[1]>range[2] || range[2]>range[3] {return false}
		}
	}
	return true
}

layers_json_valid :: proc(value: json.Value) -> bool {
	array,ok := value.(json.Array)
	if !ok || len(array)>MAX_LAYERS {return false}
	for item in array {
		object,ok := item.(json.Object); if !ok {return false}
		for key,field in object {
			switch key {
			case "name","material": if _,valid:=field.(json.String); !valid {return false}
			case "weight": if _,valid:=jsonutil.number(field); !valid {return false}
			case "tile_size","height","slope":
				values,valid := field.(json.Array)
				if !valid || len(values)!=(2 if key=="tile_size" else 4) {return false}
				for n in values {if _,valid:=jsonutil.number(n); !valid {return false}}
			case: return false
			}
		}
	}
	return true
}

layers_from_json :: proc(object: json.Object) -> ([]Layer,bool) {
	value,found := object["layers"]; if !found {return nil,true}
	if !layers_json_valid(value) {return nil,false}
	array := value.(json.Array)
	layers := make([]Layer,len(array),context.temp_allocator)
	for item,i in array {
		layers[i]=default_layer()
		bytes,_ := json.marshal(item,allocator=context.temp_allocator)
		if json.unmarshal(bytes,&layers[i],allocator=context.temp_allocator)!=nil {return nil,false}
	}
	return layers,true
}

clone_layer_fields :: proc(target:^Description,source:Description) {
	target.layers=make([]Layer,len(source.layers))
	for layer,i in source.layers {
		target.layers[i]=layer
		target.layers[i].name,_=strings.clone(layer.name)
		target.layers[i].material,_=strings.clone(layer.material)
	}
	target.control_maps=make([]string,len(source.control_maps))
	for path,i in source.control_maps {target.control_maps[i],_=strings.clone(path)}
}
