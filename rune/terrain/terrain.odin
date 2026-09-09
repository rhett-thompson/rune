package terrain

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "rune:jsonutil"
import stbi "vendor:stb/image"

// CPU-only terrain data. Paths in the descriptor are project-relative.
// Dimensions count samples, so a 257 x 257 map contains 256 x 256 cells.
Description :: struct {
	heightmap: string,
	resolution: [2]int,
	size: [2]f32,
	height_scale: f32,
	height_offset: f32,
	chunk_cells: int,
	uv_scale: [2]f32,
	material: string,
}

Data :: struct {
	description: Description,
	heights: []f32,
}

default_description :: proc() -> Description {
	return {size = {256,256}, height_scale = 32, chunk_cells = 64, uv_scale = {16,16}}
}

description_valid :: proc(d: Description) -> bool {
	if d.heightmap == "" {return false}
	for n in d.resolution {if n < 2 || n > 513 {return false}}
	for n in d.size {if !(n >= 0.01 && n <= 100000) {return false}}
	if !(d.height_scale >= 0 && d.height_scale <= 100000) || !(d.height_offset >= -100000 && d.height_offset <= 100000) {return false}
	if d.chunk_cells < 8 || d.chunk_cells > 128 || (d.chunk_cells & (d.chunk_cells-1)) != 0 {return false}
	for n in d.uv_scale {if !(n > 0 && n <= 4096) {return false}}
	return true
}

resolve :: proc(root, path: string) -> string {
	if filepath.is_abs(path) {return path}
	result,_ := filepath.join({root, path}, context.temp_allocator)
	return result
}

// Strings and samples in successful results are owned; destroy releases them.
// watched_heightmap is scratch-owned, even on an invalid/missing heightmap.
load :: proc(root, path: string) -> (result: Data, watched_heightmap: string, error: string) {
	bytes, ok := os.read_entire_file(resolve(root,path), context.temp_allocator)
	if ok != nil {return {}, "", "could not read terrain descriptor"}
	d := default_description()
	value: json.Value
	if json.unmarshal(bytes,&value,allocator=context.temp_allocator) != nil {return {},"","invalid terrain JSON"}
	object,is_object := value.(json.Object)
	if !is_object {return {},"","terrain descriptor must be an object"}
	for key,field in object {
		valid := true
		switch key {
		case "$schema","heightmap","material":
			_,valid = field.(json.String)
		case "resolution","size","uv_scale":
			array,is_array := field.(json.Array)
			valid = is_array && len(array)==2
			if valid {for number in array {
				_,is_number := jsonutil.number(number)
				valid = valid && is_number
				if key=="resolution" {_,integer := number.(json.Integer); valid = valid && integer}
			}}
		case "chunk_cells":
			_,valid = field.(json.Integer)
		case "height_scale","height_offset":
			_,valid = jsonutil.number(field)
		case:
			return {},"",fmt.tprintf("unknown terrain field: %s",key)
		}
		if !valid {return {},"",fmt.tprintf("invalid terrain field type or array size: %s",key)}
	}
	delete_key(&object,"$schema")
	clean,_ := json.marshal(object,allocator=context.temp_allocator)
	if err := json.unmarshal(clean, &d, allocator = context.temp_allocator); err != nil {
		return {}, "", fmt.tprintf("invalid terrain descriptor: %v", err)
	}
	if !description_valid(d) {return {}, d.heightmap, "invalid terrain settings: resolution 2..513, positive size/UV scale, bounded finite heights, chunk_cells 8/16/32/64/128 required"}
	samples, read_ok := os.read_entire_file(resolve(root,d.heightmap), context.temp_allocator)
	if read_ok != nil {return {}, d.heightmap, "could not read heightmap"}
	count := d.resolution[0]*d.resolution[1]
	heights := make([]f32, count)
	ext := strings.to_lower(filepath.ext(d.heightmap), context.temp_allocator)
	if ext == ".r16" {
		if len(samples) != count*2 {delete(heights); return {},d.heightmap,"r16 byte count must equal width * height * 2 (unsigned little-endian)"}
		for &h,i in heights {
			v := u16(samples[2*i]) | (u16(samples[2*i+1]) << 8)
			h = d.height_offset + f32(v)/65535*d.height_scale
		}
	} else if ext == ".png" {
		x,y,channels:i32
		if len(samples) > 64*1024*1024 || len(samples) == 0 ||
		   stbi.info_from_memory(raw_data(samples),i32(len(samples)),&x,&y,&channels) == 0 ||
		   int(x) != d.resolution[0] || int(y) != d.resolution[1] || channels != 1 {
			delete(heights); return {},d.heightmap,"PNG must be grayscale without alpha and match resolution (maximum 64 MiB)"
		}
		pixels := stbi.load_16_from_memory(raw_data(samples),i32(len(samples)),&x,&y,&channels,1)
		if pixels == nil {delete(heights); return {},d.heightmap,"could not decode PNG heightmap"}
		for &h,i in heights {h = d.height_offset + f32(pixels[i])/65535*d.height_scale}
		stbi.image_free(pixels)
	} else {delete(heights); return {},d.heightmap,"heightmap must be grayscale PNG or unsigned little-endian .r16"}
	owned := d
	owned.heightmap,_ = strings.clone(d.heightmap)
	owned.material,_ = strings.clone(d.material)
	return {owned,heights},d.heightmap,""
}

clone :: proc(data: Data) -> Data {
	result := data
	result.description.heightmap,_ = strings.clone(data.description.heightmap)
	result.description.material,_ = strings.clone(data.description.material)
	result.heights = make([]f32,len(data.heights))
	copy(result.heights,data.heights)
	return result
}

destroy :: proc(data: ^Data) {
	delete(data.heights)
	delete(data.description.heightmap)
	delete(data.description.material)
	data^ = {}
}

position :: proc(data: Data, x,z: int) -> [3]f32 {
	d := data.description
	return {f32(x)*d.size[0]/f32(d.resolution[0]-1),data.heights[z*d.resolution[0]+x],f32(z)*d.size[1]/f32(d.resolution[1]-1)}
}

// Use global neighbors even on chunk borders so adjoining normals agree.
normal :: proc(data: Data, x,z: int) -> [3]f32 {
	d := data.description
	a := position(data,max(0,x-1),z)
	b := position(data,min(d.resolution[0]-1,x+1),z)
	c := position(data,x,max(0,z-1))
	e := position(data,x,min(d.resolution[1]-1,z+1))
	return linalg.normalize(linalg.cross(e-c,b-a))
}

// Two upward-wound triangles sharing the top-right / bottom-left diagonal.
// Rendering and collision must use this exact topology.
cell_indices :: proc(x,z,stride: int) -> [6]u32 {
	a := u32(z*stride+x)
	b,c,d := a+1,a+u32(stride),a+u32(stride)+1
	return {a,c,b,b,c,d}
}

// Piecewise planar height, matching triangles rather than bilinear smoothing.
sample_height :: proc(data: Data, x,z: f32) -> (f32,bool) {
	d := data.description
	if len(data.heights) == 0 || !(x >= 0 && x <= d.size[0] && z >= 0 && z <= d.size[1]) {return 0,false}
	gx,gz := x/d.size[0]*f32(d.resolution[0]-1), z/d.size[1]*f32(d.resolution[1]-1)
	ix,iz := min(int(math.floor(gx)),d.resolution[0]-2),min(int(math.floor(gz)),d.resolution[1]-2)
	u,v := gx-f32(ix),gz-f32(iz)
	a,b := position(data,ix,iz)[1],position(data,ix+1,iz)[1]
	c,e := position(data,ix,iz+1)[1],position(data,ix+1,iz+1)[1]
	if u+v <= 1 {return a+(b-a)*u+(c-a)*v,true}
	return e+(c-e)*(1-u)+(b-e)*(1-v),true
}
