package terrain

import "core:encoding/json"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "rune:jsonutil"

MAX_DETAIL_TYPES :: 32
MAX_DETAIL_COUNT :: 100000
MAX_TERRAIN_DETAILS :: 250000

Detail :: struct {
	name,kind,model,material:string,
	count,seed:int,
	scale,height,slope:[2]f32,
	draw_distance:f32,
	align_to_normal,shadows:bool,
}

default_detail :: proc(kind:string="grass") -> Detail {
	return {kind=kind,count=1000,scale={0.8,1.2},height={-100000,100000},slope={0,35},
		draw_distance=60 if kind=="grass" else 250,align_to_normal=kind=="rock",shadows=kind!="grass"}
}

details_valid :: proc(details:[]Detail) -> bool {
	if len(details)>MAX_DETAIL_TYPES {return false}
	total:=0
	for d in details {
		if d.kind!="grass" && d.kind!="tree" && d.kind!="rock" && d.kind!="model" {return false}
		if (d.kind=="model")!=(d.model!="") {return false}
		if d.count<0 || d.count>MAX_DETAIL_COUNT || d.seed<0 || d.seed>65535 {return false}
		total+=d.count
		if total>MAX_TERRAIN_DETAILS {return false}
		if !(d.scale[0]>=0.01 && d.scale[1]<=100 && d.scale[0]<=d.scale[1]) {return false}
		if !(d.height[0]>=-100000 && d.height[1]<=100000 && d.height[0]<=d.height[1]) {return false}
		if !(d.slope[0]>=0 && d.slope[1]<=90 && d.slope[0]<=d.slope[1]) {return false}
		if !(d.draw_distance>=1 && d.draw_distance<=10000) {return false}
	}
	return true
}

details_json_valid :: proc(value:json.Value) -> bool {
	array,ok:=value.(json.Array); if !ok || len(array)>MAX_DETAIL_TYPES {return false}
	for item in array {
		object,ok:=item.(json.Object); if !ok {return false}
		for key,value in object {
			switch key {
			case "name","kind","model","material": if _,ok:=value.(json.String); !ok {return false}
			case "count","seed": if _,ok:=value.(json.Integer); !ok {return false}
			case "draw_distance": if _,ok:=jsonutil.number(value); !ok {return false}
			case "align_to_normal","shadows": if _,ok:=value.(json.Boolean); !ok {return false}
			case "scale","height","slope":
				values,ok:=value.(json.Array); if !ok || len(values)!=2 {return false}
				for n in values {if _,ok:=jsonutil.number(n); !ok {return false}}
			case: return false
			}
		}
	}
	return true
}

details_from_json :: proc(object:json.Object) -> ([]Detail,bool) {
	value,found:=object["details"]; if !found {return nil,true}
	if !details_json_valid(value) {return nil,false}
	array:=value.(json.Array)
	result:=make([]Detail,len(array),context.temp_allocator)
	for item,i in array {
		fields:=item.(json.Object)
		kind:="grass"
		if value,found:=fields["kind"]; found {kind=value.(json.String)}
		result[i]=default_detail(kind)
		bytes,_:=json.marshal(item,allocator=context.temp_allocator)
		if json.unmarshal(bytes,&result[i],allocator=context.temp_allocator)!=nil {return nil,false}
	}
	return result,details_valid(result)
}

clone_details :: proc(details:[]Detail) -> []Detail {
	result:=make([]Detail,len(details))
	for d,i in details {
		result[i]=d
		result[i].name,_=strings.clone(d.name); result[i].kind,_=strings.clone(d.kind)
		result[i].model,_=strings.clone(d.model); result[i].material,_=strings.clone(d.material)
	}
	return result
}

Detail_Instance :: struct {position,normal:[3]f32, yaw,scale,shade:f32}

detail_random :: proc(seed,index,stream:u32) -> f32 {
	h:=seed*374761393+index*668265263+stream*2246822519
	h=(h~(h>>13))*1274126177; h=h~(h>>16)
	return f32(h&0x00ffffff)/16777216.0
}

// Plane normal of the same triangle used by rendering and collision.
sample_surface_normal :: proc(data:Data,x,z:f32) -> [3]f32 {
	d:=data.description
	gx,gz:=x/d.size[0]*f32(d.resolution[0]-1),z/d.size[1]*f32(d.resolution[1]-1)
	ix,iz:=clamp(int(math.floor(gx)),0,d.resolution[0]-2),clamp(int(math.floor(gz)),0,d.resolution[1]-2)
	a,b:=position(data,ix,iz),position(data,ix+1,iz)
	c,e:=position(data,ix,iz+1),position(data,ix+1,iz+1)
	if gx-f32(ix)+gz-f32(iz)<=1 {return linalg.normalize(linalg.cross(c-a,b-a))}
	return linalg.normalize(linalg.cross(c-b,e-b))
}

// Count is the number of deterministic candidate cells; rejected slopes/heights
// reduce the final population. No random state or ECS entities are created.
scatter_details :: proc(data:Data,d:Detail) -> [dynamic]Detail_Instance {
	result:=make([dynamic]Detail_Instance)
	if d.count==0 || len(data.heights)==0 || !details_valid([]Detail{d}) {return result}
	size:=data.description.size
	columns:=min(d.count,max(1,int(math.ceil(math.sqrt(f32(d.count)*size[0]/size[1])))))
	rows:=(d.count+columns-1)/columns
	for i in 0..<d.count {
		x:=(f32(i%columns)+0.15+0.7*detail_random(u32(d.seed),u32(i),0))/f32(columns)*size[0]
		z:=(f32(i/columns)+0.15+0.7*detail_random(u32(d.seed),u32(i),1))/f32(rows)*size[1]
		y,ok:=sample_height(data,x,z); if !ok || y<d.height[0] || y>d.height[1] {continue}
		n:=sample_surface_normal(data,x,z)
		slope:=math.acos(clamp(n[1],-1,1))*180/f32(math.PI)
		if slope<d.slope[0] || slope>d.slope[1] {continue}
		append(&result,Detail_Instance{position={x,y,z},normal=n,
			yaw=detail_random(u32(d.seed),u32(i),2)*2*f32(math.PI),
			scale=d.scale[0]+(d.scale[1]-d.scale[0])*detail_random(u32(d.seed),u32(i),3),
			shade=0.78+0.22*detail_random(u32(d.seed),u32(i),4)})
	}
	return result
}
